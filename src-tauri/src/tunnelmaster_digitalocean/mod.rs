mod client;
mod migration;
mod storage;

use std::{
    collections::HashMap,
    sync::{
        LazyLock,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};

use tokio::sync::Mutex;

use crate::cmd::{CmdResult, CommandFailure};
use client::{DigitalOceanClient, parse_droplet_id, parse_token};
use storage::CredentialStore;

pub use client::{DigitalOceanBandwidthReport, DigitalOceanDropletSummary, DigitalOceanMonthlyTransfer};
pub use storage::{DigitalOceanCredentialStorage, DigitalOceanSettings};

static CLIENT: LazyLock<CmdResult<DigitalOceanClient>> = LazyLock::new(DigitalOceanClient::new);
static SETTINGS_LOCK: Mutex<()> = Mutex::const_new(());
static REVISION: AtomicU64 = AtomicU64::new(0);
static REPORTS: LazyLock<Mutex<HashMap<u32, Cached<DigitalOceanBandwidthReport>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static MONTHLY: Mutex<Option<Cached<DigitalOceanMonthlyTransfer>>> = Mutex::const_new(None);
const REPORT_TTL: Duration = Duration::from_secs(90);
const MONTHLY_TTL: Duration = Duration::from_secs(300);

struct Cached<T> {
    revision: u64,
    droplet_id: u64,
    fetched_at: Instant,
    value: T,
}

impl<T: Clone> Cached<T> {
    fn fresh(&self, ttl: Duration, expected: Option<u64>, requested_at: Option<Instant>) -> CmdResult<Option<T>> {
        if self.revision != REVISION.load(Ordering::Acquire)
            || self.fetched_at.elapsed() >= ttl
            || requested_at.is_some_and(|request| self.fetched_at < request)
        {
            return Ok(None);
        }
        check_droplet(self.droplet_id, expected)?;
        Ok(Some(self.value.clone()))
    }

    fn new(revision: u64, droplet_id: u64, value: T) -> CmdResult<Self> {
        if revision != REVISION.load(Ordering::Acquire) {
            return Err(settings_changed());
        }
        Ok(Self {
            revision,
            droplet_id,
            fetched_at: Instant::now(),
            value,
        })
    }
}

fn settings_changed() -> CommandFailure {
    CommandFailure::coded(
        "digital_ocean_settings_changed",
        "DigitalOcean settings changed while loading. Refresh to see the current Droplet.",
    )
}

fn check_droplet(actual: u64, expected: Option<u64>) -> CmdResult<()> {
    if expected.is_some_and(|id| id != actual) {
        return Err(settings_changed());
    }
    Ok(())
}

fn api() -> CmdResult<&'static DigitalOceanClient> {
    CLIENT.as_ref().map_err(Clone::clone)
}

async fn access_store<T: Send + 'static>(
    operation: impl FnOnce(CredentialStore) -> CmdResult<T> + Send + 'static,
) -> CmdResult<T> {
    tokio::task::spawn_blocking(|| operation(CredentialStore::open()?))
        .await
        .map_err(|_| {
            CommandFailure::coded(
                "digital_ocean_storage",
                "The DigitalOcean credential operation could not complete.",
            )
        })?
}

async fn current_credentials(expected: Option<u64>) -> CmdResult<(u64, u64, String)> {
    let _settings = SETTINGS_LOCK.lock().await;
    let (id, token) = access_store(move |store| store.credentials(expected)).await?;
    Ok((REVISION.load(Ordering::Acquire), id, token))
}

#[tauri::command]
#[specta::specta]
pub async fn get_tunnelmaster_do_settings() -> CmdResult<DigitalOceanSettings> {
    let _settings = SETTINGS_LOCK.lock().await;
    access_store(|store| store.summary()).await
}

#[tauri::command]
#[specta::specta]
pub async fn save_tunnelmaster_do_credentials(
    droplet_id: String,
    token: String,
    storage: DigitalOceanCredentialStorage,
) -> CmdResult<DigitalOceanSettings> {
    let id = parse_droplet_id(&droplet_id)?;
    let token = parse_token(&token)?.to_owned();
    let _settings = SETTINGS_LOCK.lock().await;
    api()?.validate(id, &token).await?;
    access_store(move |store| {
        let updated = store.save(id, token, storage)?;
        REVISION.fetch_add(1, Ordering::Release);
        Ok(updated)
    })
    .await
}

#[tauri::command]
#[specta::specta]
pub async fn list_tunnelmaster_do_droplets(
    token: Option<String>,
    expected_droplet_id: Option<String>,
) -> CmdResult<Vec<DigitalOceanDropletSummary>> {
    if let Some(token) = token {
        return api()?.droplets(parse_token(&token)?).await;
    }
    let expected = expected_droplet_id.as_deref().map(parse_droplet_id).transpose()?;
    let (revision, _, token) = current_credentials(expected).await?;
    let droplets = api()?.droplets(&token).await?;
    if revision != REVISION.load(Ordering::Acquire) {
        return Err(settings_changed());
    }
    Ok(droplets)
}

#[tauri::command]
#[specta::specta]
pub async fn select_tunnelmaster_do_droplet(droplet_id: String) -> CmdResult<DigitalOceanSettings> {
    let id = parse_droplet_id(&droplet_id)?;
    let _settings = SETTINGS_LOCK.lock().await;
    let (_, token) = access_store(|store| store.credentials(None)).await?;
    api()?.validate(id, &token).await?;
    access_store(move |store| {
        let updated = store.select(id)?;
        REVISION.fetch_add(1, Ordering::Release);
        Ok(updated)
    })
    .await
}

#[tauri::command]
#[specta::specta]
pub async fn set_tunnelmaster_do_storage(
    storage: DigitalOceanCredentialStorage,
    expected_droplet_id: Option<String>,
) -> CmdResult<DigitalOceanSettings> {
    let expected = expected_droplet_id.as_deref().map(parse_droplet_id).transpose()?;
    let _settings = SETTINGS_LOCK.lock().await;
    access_store(move |store| {
        let updated = store.change_storage(storage, expected)?;
        REVISION.fetch_add(1, Ordering::Release);
        Ok(updated)
    })
    .await
}

#[tauri::command]
#[specta::specta]
pub async fn get_tunnelmaster_do_report(
    days: u32,
    expected_droplet_id: Option<String>,
    force: Option<bool>,
) -> CmdResult<DigitalOceanBandwidthReport> {
    let expected = expected_droplet_id.as_deref().map(parse_droplet_id).transpose()?;
    let requested_at = force.unwrap_or_default().then(Instant::now);
    let mut reports = REPORTS.lock().await;
    if let Some(cached) = reports.get(&days)
        && let Some(value) = cached.fresh(REPORT_TTL, expected, requested_at)?
    {
        return Ok(value);
    }
    let (revision, id, token) = current_credentials(expected).await?;
    let report = api()?.report(id, &token, days).await?;
    reports.insert(days, Cached::new(revision, id, report.clone())?);
    drop(reports);
    Ok(report)
}

#[tauri::command]
#[specta::specta]
pub async fn get_tunnelmaster_do_monthly_transfer(
    expected_droplet_id: Option<String>,
    force: Option<bool>,
) -> CmdResult<DigitalOceanMonthlyTransfer> {
    let expected = expected_droplet_id.as_deref().map(parse_droplet_id).transpose()?;
    let requested_at = force.unwrap_or_default().then(Instant::now);
    let mut monthly = MONTHLY.lock().await;
    if let Some(cached) = monthly.as_ref()
        && cached.value.is_current_month()
        && let Some(value) = cached.fresh(MONTHLY_TTL, expected, requested_at)?
    {
        return Ok(value);
    }
    let (revision, id, token) = current_credentials(expected).await?;
    let report = api()?.monthly_transfer(id, &token).await?;
    *monthly = Some(Cached::new(revision, id, report.clone())?);
    drop(monthly);
    Ok(report)
}

#[tauri::command]
#[specta::specta]
pub async fn migrate_tunnelmaster_do_credentials() -> CmdResult<DigitalOceanSettings> {
    let _settings = SETTINGS_LOCK.lock().await;
    let (id, token) = access_store(|store| {
        store.require_empty()?;
        migration::native_credentials()
    })
    .await?;
    api()?.validate(id, &token).await?;
    access_store(move |store| {
        store.require_empty()?;
        let updated = store.save(id, token, DigitalOceanCredentialStorage::LocalFile)?;
        REVISION.fetch_add(1, Ordering::Release);
        Ok(updated)
    })
    .await
}

#[tauri::command]
#[specta::specta]
pub async fn clear_tunnelmaster_do_credentials() -> CmdResult<DigitalOceanSettings> {
    let _settings = SETTINGS_LOCK.lock().await;
    access_store(|store| {
        let updated = store.clear()?;
        REVISION.fetch_add(1, Ordering::Release);
        Ok(updated)
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::{Cached, CmdResult, Duration, Ordering, REPORT_TTL, REVISION};

    #[test]
    fn a_cached_report_cannot_be_returned_for_another_droplet() -> CmdResult<()> {
        let cached = Cached::new(REVISION.load(Ordering::Acquire), 42, "synthetic report")?;
        assert_eq!(cached.fresh(REPORT_TTL, Some(42), None)?, Some("synthetic report"));
        assert!(cached.fresh(REPORT_TTL, Some(21), None).is_err());
        Ok(())
    }

    #[test]
    fn manual_refresh_reuses_only_reports_completed_after_it_was_requested() -> CmdResult<()> {
        let cached = Cached::new(REVISION.load(Ordering::Acquire), 42, "synthetic report")?;
        let step = Duration::from_millis(1);
        assert_eq!(
            cached.fresh(REPORT_TTL, Some(42), Some(cached.fetched_at + step))?,
            None
        );
        assert_eq!(
            cached.fresh(REPORT_TTL, Some(42), Some(cached.fetched_at - step))?,
            Some("synthetic report")
        );
        Ok(())
    }
}
