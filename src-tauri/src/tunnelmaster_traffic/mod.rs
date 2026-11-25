pub(crate) mod egress;
mod history;
pub(crate) mod panel;

use crate::{
    cmd::{CmdResult, CommandFailure},
    core::{CoreManager, handle::Handle},
    process::AsyncHandler,
    utils::dirs,
};
use chrono::Utc;
use history::{History, STORAGE_BUCKET, StorageSample};
use parking_lot::RwLock;
use serde::Serialize;
use specta::Type;
use std::{
    collections::VecDeque,
    path::PathBuf,
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};

const SAMPLE_INTERVAL: Duration = Duration::from_secs(5);
static LIVE: RwLock<LiveState> = RwLock::new(LiveState {
    current: LiveSample::empty(),
    rates: VecDeque::new(),
});
static STARTED: AtomicBool = AtomicBool::new(false);

#[derive(Debug, Clone, Serialize, Type)]
pub struct LocalTrafficBucket {
    pub start: i64,
    pub upload: u64,
    pub download: u64,
    pub samples: u32,
    pub connected_seconds: f64,
    pub peak_download_rate: u64,
    pub peak_upload_rate: u64,
    pub peak_connections: Option<u32>,
    pub sessions_started: u32,
}

#[derive(Serialize, Type)]
pub struct LocalHistory {
    pub buckets: Vec<LocalTrafficBucket>,
    pub from: i64,
    pub until: i64,
    pub bucket_seconds: i64,
    pub sampled_at: Option<i64>,
    pub current_upload: u64,
    pub current_download: u64,
    pub sampling: bool,
    pub live_rates: Vec<LiveTrafficRate>,
    pub previous: Option<LocalTrafficTotals>,
}

#[derive(Clone, Copy, Serialize, Type)]
pub struct LiveTrafficRate {
    pub at: i64,
    pub upload: u64,
    pub download: u64,
}

#[derive(Debug, Clone, Copy, Serialize, Type)]
pub struct LocalTrafficTotals {
    pub upload: u64,
    pub download: u64,
}

struct LiveState {
    current: LiveSample,
    rates: VecDeque<LiveTrafficRate>,
}

impl LiveState {
    fn update(&mut self, sample: LiveSample) {
        self.current = sample;
        if let Some(at) = sample.time.filter(|_| sample.sampling) {
            self.rates.push_back(LiveTrafficRate {
                at,
                upload: sample.upload_rate,
                download: sample.download_rate,
            });
        }
        while self.rates.len() > 24 {
            self.rates.pop_front();
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct LiveSample {
    time: Option<i64>,
    upload_rate: u64,
    download_rate: u64,
    sampling: bool,
}

impl LiveSample {
    const fn empty() -> Self {
        Self {
            time: None,
            upload_rate: 0,
            download_rate: 0,
            sampling: false,
        }
    }
}

#[derive(Clone, Copy)]
struct Reading {
    generation: u64,
    time: i64,
    observed_at: Instant,
    route_active: bool,
    upload: u64,
    download: u64,
}

fn to_sample(reading: Reading, baseline: Option<Reading>, connections: Option<u32>) -> StorageSample {
    let before = baseline.filter(|last| reading.generation == last.generation);
    let elapsed = before.map_or(Duration::ZERO, |last| {
        reading.observed_at.saturating_duration_since(last.observed_at)
    });
    let timely = !elapsed.is_zero() && elapsed <= SAMPLE_INTERVAL * 3;
    let connected_seconds = if timely && reading.route_active && before.is_some_and(|last| last.route_active) {
        elapsed.as_secs_f64()
    } else {
        0.0
    };
    let difference = |current: u64, previous| match previous {
        Some(previous) => current.checked_sub(previous).unwrap_or(current),
        None if baseline.is_some() => current,
        None => 0,
    };
    let upload = difference(reading.upload, before.map(|last| last.upload));
    let download = difference(reading.download, before.map(|last| last.download));
    let rates = timely && before.is_some_and(|last| reading.upload >= last.upload && reading.download >= last.download);
    let (up_rate, down_rate) = if rates {
        (
            (upload as f64 / elapsed.as_secs_f64()).round() as u64,
            (download as f64 / elapsed.as_secs_f64()).round() as u64,
        )
    } else {
        (0, 0)
    };
    let new_session =
        reading.route_active && baseline.is_none_or(|last| !last.route_active || last.generation != reading.generation);
    StorageSample {
        timestamp: reading.time,
        upload,
        download,
        connected_seconds,
        peak_download_rate: down_rate,
        peak_upload_rate: up_rate,
        sessions_started: u32::from(new_session),
        peak_connections: connections,
        samples: u32::from(baseline.is_some()),
    }
}

pub(crate) fn start() {
    if STARTED.swap(true, Ordering::AcqRel) {
        return;
    }
    AsyncHandler::spawn(sample_continuously);
}

async fn sample_continuously() {
    let mut timer = tokio::time::interval(SAMPLE_INTERVAL);
    timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut baseline: Option<Reading> = None;
    let mut pending = Vec::new();
    loop {
        timer.tick().await;
        if Handle::global().is_exiting() {
            break;
        }
        let mut sampling = false;
        if let Some(generation) = CoreManager::global().current_core_readiness_generation()
            && let Ok((reading, connections)) = read_current(generation).await
            && CoreManager::global().current_core_readiness_generation() == Some(generation)
        {
            let sample = to_sample(reading, baseline, connections);
            sampling = baseline.is_some_and(|last| {
                last.generation == reading.generation
                    && reading.observed_at.saturating_duration_since(last.observed_at) <= SAMPLE_INTERVAL * 3
                    && reading.upload >= last.upload
                    && reading.download >= last.download
            });
            baseline = Some(reading);
            LIVE.write().update(LiveSample {
                time: Some(reading.time),
                upload_rate: sample.peak_upload_rate,
                download_rate: sample.peak_download_rate,
                sampling,
            });
            pending.push(sample);
        }
        if !sampling {
            LIVE.write().current.sampling = false;
        }
        flush(&mut pending).await;
    }
    flush(&mut pending).await;
}

async fn flush(pending: &mut Vec<StorageSample>) {
    if pending.is_empty() {
        return;
    }
    let samples = std::mem::take(pending);
    let result = tokio::task::spawn_blocking(move || {
        let result = open_history().and_then(|mut db| db.append(&samples));
        (samples, result)
    })
    .await;
    if let Ok((mut samples, Err(error))) = result {
        clash_verge_logging::logging!(warn, clash_verge_logging::Type::File, "Traffic history: {error:#}");
        samples.retain(|sample| sample.timestamp >= Utc::now().timestamp() - 3600);
        *pending = samples;
    }
}

async fn read_current(generation: u64) -> anyhow::Result<(Reading, Option<u32>)> {
    let settings = crate::config::Config::verge().await.data_arc();
    let route_active = settings.enable_system_proxy.unwrap_or_default() || settings.enable_tun_mode.unwrap_or_default();
    let state = tokio::time::timeout(Duration::from_secs(2), Handle::mihomo().get_connections()).await??;
    let reading = Reading {
        generation,
        time: Utc::now().timestamp(),
        observed_at: Instant::now(),
        route_active,
        upload: state.upload_total,
        download: state.download_total,
    };
    Ok((
        reading,
        state
            .connections
            .map(|values| values.len().try_into().unwrap_or(u32::MAX)),
    ))
}

fn open_history() -> anyhow::Result<History> {
    let root = dirs::app_home_dir()?.join("tunnelmaster-private");
    History::open(&root.join("traffic-history.sqlite3"), legacy_history_path())
}

fn legacy_history_path() -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    if let Some(root) = ::dirs::data_dir() {
        let legacy = root.join("TunnelMaster").join("traffic-history.sqlite3");
        if legacy.is_file() {
            return Some(legacy);
        }
    }
    None
}

fn window(range: &str, until: i64) -> Option<(i64, i64)> {
    let (seconds, width) = match range {
        "60s" => (60, SAMPLE_INTERVAL.as_secs() as i64),
        "60m" => (3600, STORAGE_BUCKET),
        "24h" => (86400, 3600),
        "7d" => (7 * 86400, 6 * 3600),
        "14d" => (14 * 86400, 86400),
        "30d" => (30 * 86400, 86400),
        "90d" => (90 * 86400, 3 * 86400),
        "365d" => (365 * 86400, 7 * 86400),
        _ => return None,
    };
    let from = if range == "60s" {
        until - seconds
    } else {
        (until - seconds).div_euclid(width) * width
    };
    Some((from, width))
}

#[tauri::command]
#[specta::specta]
pub async fn tunnelmaster_local_history(range: String) -> CmdResult<LocalHistory> {
    let until = Utc::now().timestamp() + 1;
    let (from, bucket_seconds) = window(&range, until).ok_or_else(|| CommandFailure::plain("Invalid traffic range"))?;
    let (buckets, previous) = if range == "60s" {
        (Vec::new(), None)
    } else {
        tokio::task::spawn_blocking(move || {
            let db = open_history()?;
            let buckets = db.read(from, until, bucket_seconds)?;
            let previous = db.totals(from - (until - from), from)?;
            Ok::<_, anyhow::Error>((buckets, previous))
        })
        .await
        .map_err(CommandFailure::plain)?
        .map_err(CommandFailure::plain)?
    };
    let state = LIVE.read();
    let live = state.current;
    let live_rates = state
        .rates
        .iter()
        .filter(|rate| rate.at >= until - 60 && rate.at < until)
        .copied()
        .collect();
    drop(state);
    Ok(LocalHistory {
        buckets,
        from,
        until,
        bucket_seconds,
        sampled_at: live.time,
        current_upload: if live.sampling { live.upload_rate } else { 0 },
        current_download: if live.sampling { live.download_rate } else { 0 },
        sampling: live.sampling,
        live_rates,
        previous,
    })
}

#[cfg(test)]
mod tests {
    use super::{Duration, Instant, Reading, to_sample};

    #[test]
    fn reconnect_does_not_duplicate_lifetime_counters() {
        let before = Reading {
            generation: 1,
            time: 5,
            observed_at: Instant::now(),
            route_active: true,
            upload: 300,
            download: 400,
        };
        assert_eq!(to_sample(before, None, None).upload, 0);
        let after = Reading {
            time: 10,
            observed_at: before.observed_at + Duration::from_secs(5),
            download: 1000,
            ..before
        };
        let delta = to_sample(after, Some(before), Some(3));
        assert_eq!(
            (delta.download, delta.peak_download_rate, delta.peak_connections),
            (600, 120, Some(3))
        );
        let one_reset = Reading {
            upload: 11,
            download: 1100,
            ..after
        };
        let delta = to_sample(one_reset, Some(after), None);
        assert_eq!((delta.upload, delta.download), (11, 100));
        let restart = Reading {
            generation: 2,
            time: 15,
            upload: 12,
            download: 40,
            ..before
        };
        let delta = to_sample(restart, Some(after), None);
        assert_eq!(
            (
                delta.upload,
                delta.download,
                delta.connected_seconds,
                delta.sessions_started
            ),
            (12, 40, 0.0, 1)
        );
    }
}
