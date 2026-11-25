use std::{collections::HashSet, time::Duration};

use chrono::{DateTime, Datelike as _, Months, TimeZone as _, Utc};
use reqwest::{Client, StatusCode, Url, header, redirect};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use specta::Type;

use crate::cmd::{CmdResult, CommandFailure};

const API: &str = "https://api.digitalocean.com";
const BANDWIDTH_PATH: &str = "/v2/monitoring/metrics/droplet/bandwidth";
const DAY: i64 = 86_400;
const MAX_GAP: i64 = 1_800;
const GIB: f64 = 1_073_741_824.0;

#[derive(Clone, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct DigitalOceanBandwidthSample {
    timestamp: f64,
    mbps: f64,
}

#[derive(Clone, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct DigitalOceanBandwidthSeries {
    samples: Vec<DigitalOceanBandwidthSample>,
    estimated_bytes: Option<f64>,
    covered_seconds: f64,
    peak_mbps: Option<f64>,
}

#[derive(Clone, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct DigitalOceanBandwidthReport {
    from: i64,
    until: i64,
    inbound: DigitalOceanBandwidthSeries,
    outbound: DigitalOceanBandwidthSeries,
    bucket_seconds: i64,
    buckets: Vec<DigitalOceanBandwidthBucket>,
}

#[derive(Clone, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct DigitalOceanBandwidthBucket {
    start: i64,
    until: i64,
    inbound_bytes: Option<f64>,
    outbound_bytes: Option<f64>,
    inbound_covered_seconds: f64,
    outbound_covered_seconds: f64,
}

#[derive(Clone, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct DigitalOceanMonthlyTransfer {
    month_start: i64,
    as_of: i64,
    outbound_gib: Option<f64>,
    coverage: Option<f64>,
    plan_gib: Option<f64>,
    accrued_gib: Option<f64>,
    remaining_gib: Option<f64>,
    projected_allowance_gib: Option<f64>,
}

impl DigitalOceanMonthlyTransfer {
    pub(super) fn is_current_month(&self) -> bool {
        month_bounds(Utc::now()).is_ok_and(|(start, _)| start == self.month_start)
    }
}

#[derive(Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct DigitalOceanDropletSummary {
    id: String,
    name: String,
    region: String,
    status: Option<String>,
}

pub(super) struct DigitalOceanClient(Client);

impl DigitalOceanClient {
    pub(super) fn new() -> CmdResult<Self> {
        Client::builder()
            .redirect(redirect::Policy::none())
            .connect_timeout(Duration::from_secs(8))
            .timeout(Duration::from_secs(20))
            .build()
            .map(Self)
            .map_err(|_| network_error())
    }

    pub(super) async fn validate(&self, id: u64, token: &str) -> CmdResult<()> {
        let now = Utc::now().timestamp();
        self.bandwidth(id, token, Direction::Outbound, now - 600, now).await?;
        Ok(())
    }

    pub(super) async fn report(&self, id: u64, token: &str, days: u32) -> CmdResult<DigitalOceanBandwidthReport> {
        if !matches!(days, 1 | 7 | 14) {
            return Err(CommandFailure::coded(
                "digital_ocean_invalid_range",
                "Choose a 1-, 7-, or 14-day window.",
            ));
        }
        let until = Utc::now().timestamp();
        let from = until - i64::from(days) * DAY;
        let (inbound, outbound) = tokio::try_join!(
            self.bandwidth(id, token, Direction::Inbound, from, until),
            self.bandwidth(id, token, Direction::Outbound, from, until),
        )?;
        let bucket_seconds = if days == 1 { 3600 } else { DAY };
        let buckets = bandwidth_buckets(&inbound, &outbound, from, until, bucket_seconds);
        Ok(DigitalOceanBandwidthReport {
            from,
            until,
            inbound: inbound.series(from, until),
            outbound: outbound.series(from, until),
            bucket_seconds,
            buckets,
        })
    }

    pub(super) async fn monthly_transfer(&self, id: u64, token: &str) -> CmdResult<DigitalOceanMonthlyTransfer> {
        let now = Utc::now();
        let (month_start, month_end) = month_bounds(now)?;
        let now = now.timestamp();

        // The optional Droplet scope can be unavailable to a monitoring-only token.
        let metadata = self.droplet_metadata(id, token, now).await.ok();
        let first = metadata
            .as_ref()
            .map_or(month_start, |item| month_start.max(item.created_at));
        let mut usage = Estimate::default();
        let mut cursor = first;
        while cursor < now {
            let end = (cursor + 6 * DAY).min(now);
            // Adjacent requests overlap, but their integration intervals never do.
            let readings = self
                .bandwidth(
                    id,
                    token,
                    Direction::Outbound,
                    (cursor - MAX_GAP).max(first),
                    (end + MAX_GAP).min(now),
                )
                .await?;
            let portion = readings.estimate(cursor, end);
            usage.bytes += portion.bytes;
            usage.seconds += portion.seconds;
            cursor = end;
        }
        Ok(monthly_summary(
            month_start,
            month_end,
            now,
            first,
            metadata.and_then(|item| item.plan),
            usage,
        ))
    }

    pub(super) async fn droplets(&self, token: &str) -> CmdResult<Vec<DigitalOceanDropletSummary>> {
        const PAGE_SIZE: usize = 200;
        let mut seen = HashSet::new();
        let mut items = Vec::new();
        for page in 1..=1000 {
            let response: DropletList = self
                .get(
                    "/v2/droplets",
                    &[("per_page", PAGE_SIZE.to_string()), ("page", page.to_string())],
                    token,
                )
                .await?;
            if response.droplets.len() > PAGE_SIZE {
                return Err(invalid_response());
            }
            let more = response.has_more(page, PAGE_SIZE);
            let previous = items.len();
            for droplet in response.droplets {
                if droplet.id == 0 || droplet.region.slug.is_empty() {
                    return Err(invalid_response());
                }
                if seen.insert(droplet.id) {
                    items.push(DigitalOceanDropletSummary {
                        id: droplet.id.to_string(),
                        name: droplet.name,
                        region: droplet.region.slug,
                        status: droplet.status,
                    });
                }
            }
            if !more {
                return Ok(items);
            }
            if items.len() == previous {
                return Err(invalid_response());
            }
        }
        Err(invalid_response())
    }

    async fn bandwidth(
        &self,
        id: u64,
        token: &str,
        direction: Direction,
        from: i64,
        until: i64,
    ) -> CmdResult<Readings> {
        let id = id.to_string();
        let payload: BandwidthResponse = self
            .get(
                BANDWIDTH_PATH,
                &[
                    ("host_id", id.clone()),
                    ("interface", "public".into()),
                    ("direction", direction.as_str().into()),
                    ("start", from.to_string()),
                    ("end", until.to_string()),
                ],
                token,
            )
            .await?;
        payload.readings(&id, direction)
    }

    async fn droplet_metadata(&self, id: u64, token: &str, now: i64) -> CmdResult<DropletMetadata> {
        let detail: MetadataResponse = self.get(&format!("/v2/droplets/{id}"), &[], token).await?;
        let created_at = DateTime::parse_from_rfc3339(&detail.droplet.created_at)
            .map_err(|_| invalid_response())?
            .timestamp();
        if detail.droplet.id != id || !(0..=now).contains(&created_at) {
            return Err(invalid_response());
        }
        let plan = detail.droplet.size.and_then(Plan::from_size);
        Ok(DropletMetadata { created_at, plan })
    }

    async fn get<T: DeserializeOwned>(&self, path: &str, query: &[(&str, String)], token: &str) -> CmdResult<T> {
        let mut authorization =
            header::HeaderValue::from_str(&format!("Bearer {token}")).map_err(|_| invalid_token())?;
        authorization.set_sensitive(true);
        let mut url = Url::parse(&format!("{API}{path}")).map_err(|_| invalid_response())?;
        if !query.is_empty() {
            url.query_pairs_mut().extend_pairs(query);
        }
        let response = self
            .0
            .get(url)
            .header(header::AUTHORIZATION, authorization)
            .header(header::ACCEPT, "application/json")
            .send()
            .await
            .map_err(|_| network_error())?;
        match response.status() {
            status if status.is_success() => {}
            StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => {
                return Err(CommandFailure::coded(
                    "digital_ocean_unauthorized",
                    "DigitalOcean rejected the token, its scopes, or access to this Droplet.",
                ));
            }
            StatusCode::TOO_MANY_REQUESTS => {
                return Err(CommandFailure::coded(
                    "digital_ocean_rate_limit",
                    "DigitalOcean rate limit reached. Try again later.",
                ));
            }
            status => {
                return Err(CommandFailure::coded(
                    "digital_ocean_http",
                    format!("DigitalOcean returned HTTP {}.", status.as_u16()),
                ));
            }
        }
        response.json().await.map_err(|_| invalid_response())
    }
}

pub(super) fn parse_droplet_id(input: &str) -> CmdResult<u64> {
    let input = input.trim();
    input
        .parse::<u64>()
        .ok()
        .filter(|id| *id > 0 && input.bytes().all(|byte| byte.is_ascii_digit()))
        .ok_or_else(|| CommandFailure::coded("digital_ocean_invalid_droplet", "Enter a valid numeric Droplet ID."))
}

pub(super) fn parse_token(input: &str) -> CmdResult<&str> {
    let token = input.trim();
    if token.is_empty() || token.len() > 4096 || !token.bytes().all(|byte| byte.is_ascii_graphic()) {
        return Err(invalid_token());
    }
    Ok(token)
}

fn invalid_token() -> CommandFailure {
    CommandFailure::coded("digital_ocean_invalid_token", "Enter a valid DigitalOcean API token.")
}

fn invalid_response() -> CommandFailure {
    CommandFailure::coded(
        "digital_ocean_invalid_response",
        "DigitalOcean returned an unexpected response.",
    )
}

fn network_error() -> CommandFailure {
    CommandFailure::coded("digital_ocean_network", "Could not connect to the DigitalOcean API.")
}

#[derive(Clone, Copy)]
enum Direction {
    Inbound,
    Outbound,
}

impl Direction {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Inbound => "inbound",
            Self::Outbound => "outbound",
        }
    }
}

#[derive(Deserialize)]
struct BandwidthResponse {
    status: String,
    data: Matrix,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Matrix {
    result_type: String,
    result: Vec<Metric>,
}

#[derive(Deserialize)]
struct Metric {
    metric: MetricLabels,
    values: Vec<(f64, String)>,
}

#[derive(Deserialize)]
struct MetricLabels {
    host_id: String,
    interface: String,
    direction: String,
}

impl BandwidthResponse {
    fn readings(self, id: &str, direction: Direction) -> CmdResult<Readings> {
        if self.status != "success" || self.data.result_type != "matrix" || self.data.result.len() > 1 {
            return Err(invalid_response());
        }
        let Some(result) = self.data.result.into_iter().next() else {
            return Ok(Readings::default());
        };
        if result.metric.host_id != id
            || result.metric.interface != "public"
            || result.metric.direction != direction.as_str()
        {
            return Err(invalid_response());
        }
        Readings::from_values(result.values)
    }
}

struct Reading {
    timestamp: f64,
    mbps: Option<f64>,
}

#[derive(Default)]
struct Readings {
    points: Vec<Reading>,
    max_gap: f64,
}

#[derive(Default)]
struct Estimate {
    bytes: f64,
    seconds: f64,
}

impl Estimate {
    fn measured_bytes(&self) -> Option<f64> {
        (self.seconds > 0.0 && self.bytes.is_finite()).then_some(self.bytes)
    }
}

fn bandwidth_buckets(
    inbound: &Readings,
    outbound: &Readings,
    from: i64,
    until: i64,
    width: i64,
) -> Vec<DigitalOceanBandwidthBucket> {
    let mut buckets = Vec::new();
    let mut start = from;
    while start < until {
        let end = ((start.div_euclid(width) + 1) * width).min(until);
        let inbound = inbound.estimate(start, end);
        let outbound = outbound.estimate(start, end);
        buckets.push(DigitalOceanBandwidthBucket {
            start,
            until: end,
            inbound_bytes: inbound.measured_bytes(),
            outbound_bytes: outbound.measured_bytes(),
            inbound_covered_seconds: inbound.seconds,
            outbound_covered_seconds: outbound.seconds,
        });
        start = end;
    }
    buckets
}

impl Readings {
    fn from_values(mut values: Vec<(f64, String)>) -> CmdResult<Self> {
        values.sort_unstable_by(|left, right| left.0.total_cmp(&right.0));
        let mut points: Vec<Reading> = Vec::with_capacity(values.len());
        for (timestamp, value) in values {
            if !timestamp.is_finite() {
                return Err(invalid_response());
            }
            let mbps = value
                .parse::<f64>()
                .ok()
                .filter(|rate| rate.is_finite() && *rate >= 0.0);
            if let Some(previous) = points.last_mut().filter(|point| point.timestamp == timestamp) {
                if let (Some(previous), Some(current)) = (previous.mbps, mbps)
                    && previous != current
                {
                    return Err(invalid_response());
                }
                previous.mbps = previous.mbps.or(mbps);
            } else {
                points.push(Reading { timestamp, mbps });
            }
        }
        let mut cadence: Vec<_> = points
            .windows(2)
            .map(|pair| pair[1].timestamp - pair[0].timestamp)
            .collect();
        let max_gap = if cadence.is_empty() {
            0.0
        } else {
            let median = (cadence.len() - 1) / 2;
            let (_, midpoint, _) = cadence.select_nth_unstable_by(median, f64::total_cmp);
            (*midpoint * 1.5).min(MAX_GAP as f64)
        };
        Ok(Self { points, max_gap })
    }

    fn estimate(&self, from: i64, until: i64) -> Estimate {
        let mut result = Estimate::default();
        for pair in self.points.windows(2) {
            let (Some(first), Some(last)) = (pair[0].mbps, pair[1].mbps) else {
                continue;
            };
            let start = pair[0].timestamp;
            let end = pair[1].timestamp;
            let duration = end - start;
            let entry = (from as f64).max(start);
            let exit = (until as f64).min(end);
            if entry >= exit || duration > self.max_gap {
                continue;
            }
            let entry_rate = first + (last - first) * ((entry - start) / duration);
            let exit_rate = first + (last - first) * ((exit - start) / duration);
            result.bytes += (entry_rate * 0.5 + exit_rate * 0.5) * 125_000.0 * (exit - entry);
            result.seconds += exit - entry;
        }
        result
    }

    fn series(self, from: i64, until: i64) -> DigitalOceanBandwidthSeries {
        let estimate = self.estimate(from, until);
        let samples: Vec<_> = self
            .points
            .into_iter()
            .filter_map(|point| {
                let mbps = point.mbps?;
                ((from as f64..=until as f64).contains(&point.timestamp)).then_some(DigitalOceanBandwidthSample {
                    timestamp: point.timestamp,
                    mbps,
                })
            })
            .collect();
        let peak_mbps = samples.iter().map(|point| point.mbps).reduce(f64::max);
        DigitalOceanBandwidthSeries {
            samples,
            estimated_bytes: estimate.measured_bytes().map(f64::round),
            covered_seconds: estimate.seconds,
            peak_mbps,
        }
    }
}

#[derive(Deserialize)]
struct DropletList {
    droplets: Vec<Droplet>,
    links: Option<Links>,
    meta: Option<ListMetadata>,
}

impl DropletList {
    fn has_more(&self, page: usize, page_size: usize) -> bool {
        if self
            .links
            .as_ref()
            .and_then(|links| links.pages.as_ref())
            .is_some_and(|pages| pages.next.is_some())
        {
            return true;
        }
        self.meta
            .as_ref()
            .map_or(self.droplets.len() == page_size, |meta| meta.total > page * page_size)
    }
}

#[derive(Deserialize)]
struct Droplet {
    id: u64,
    name: String,
    region: Region,
    status: Option<String>,
}

#[derive(Deserialize)]
struct Region {
    slug: String,
}

#[derive(Deserialize)]
struct Links {
    pages: Option<Pages>,
}

#[derive(Deserialize)]
struct Pages {
    next: Option<String>,
}

#[derive(Deserialize)]
struct ListMetadata {
    total: usize,
}

#[derive(Deserialize)]
struct MetadataResponse {
    droplet: MetadataDroplet,
}

#[derive(Deserialize)]
struct MetadataDroplet {
    id: u64,
    created_at: String,
    size: Option<Size>,
}

#[derive(Deserialize)]
struct Size {
    slug: String,
    transfer: f64,
}

struct DropletMetadata {
    created_at: i64,
    plan: Option<Plan>,
}

struct Plan {
    included_gib: f64,
    uncapped: bool,
}

impl Plan {
    fn from_size(size: Size) -> Option<Self> {
        let included_gib = size.transfer * 1_000.0;
        (!size.slug.is_empty() && included_gib.is_finite() && included_gib >= 0.0).then_some(Self {
            included_gib,
            uncapped: size.slug.starts_with("s5-") || size.slug.starts_with("g5-"),
        })
    }

    fn allowance(&self, seconds: i64) -> f64 {
        let ratio = seconds as f64 / (28 * DAY) as f64;
        self.included_gib * if self.uncapped { ratio } else { ratio.min(1.0) }
    }
}

fn month_bounds(now: DateTime<Utc>) -> CmdResult<(i64, i64)> {
    let start = Utc
        .with_ymd_and_hms(now.year(), now.month(), 1, 0, 0, 0)
        .single()
        .ok_or_else(invalid_response)?;
    let end = start.checked_add_months(Months::new(1)).ok_or_else(invalid_response)?;
    Ok((start.timestamp(), end.timestamp()))
}

fn monthly_summary(
    month_start: i64,
    month_end: i64,
    now: i64,
    first: i64,
    plan: Option<Plan>,
    usage: Estimate,
) -> DigitalOceanMonthlyTransfer {
    let elapsed = now - first;
    let outbound_gib = usage.measured_bytes().map(|bytes| bytes / GIB);
    let coverage = (elapsed > 0).then(|| (usage.seconds / elapsed as f64).min(1.0));
    let accrued_gib = plan.as_ref().map(|item| item.allowance(elapsed));
    let projected_allowance_gib = plan.as_ref().map(|item| item.allowance(month_end - first));
    let remaining_gib = match (outbound_gib, coverage, projected_allowance_gib) {
        (Some(used), Some(coverage), Some(projected)) if coverage >= 0.95 => Some(projected - used),
        _ => None,
    };
    DigitalOceanMonthlyTransfer {
        month_start,
        as_of: now,
        outbound_gib,
        coverage,
        plan_gib: plan.map(|item| item.included_gib),
        accrued_gib,
        remaining_gib,
        projected_allowance_gib,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn monitoring_matrix_checks_labels_and_keeps_gaps_out_of_usage() -> CmdResult<()> {
        let matrix = json!({
            "status": "success",
            "data": {
                "resultType": "matrix",
                "result": [{
                    "metric": {"host_id": "42", "interface": "public", "direction": "outbound"},
                    "values": [[0, "2"], [60, "4"], [120, "NaN"], [180, "4"], [1200, "2"], [1260, "2"]]
                }]
            }
        });
        let decode = || serde_json::from_value::<BandwidthResponse>(matrix.clone()).map_err(|_| invalid_response());
        assert!(decode()?.readings("41", Direction::Outbound).is_err());
        assert!(decode()?.readings("42", Direction::Inbound).is_err());
        let series = decode()?.readings("42", Direction::Outbound)?.series(30, 1230);
        assert_eq!(series.samples.len(), 3);
        assert_eq!(series.covered_seconds, 60.0);
        assert_eq!(series.estimated_bytes, Some(20_625_000.0));
        assert_eq!(series.peak_mbps, Some(4.0));
        Ok(())
    }

    #[test]
    fn overlapping_slices_integrate_each_observed_instant_once() -> CmdResult<()> {
        let readings = Readings::from_values(vec![(0.0, "0".into()), (100.0, "4".into()), (200.0, "8".into())])?;
        let whole = readings.estimate(10, 190);
        let first = readings.estimate(10, 115);
        let second = readings.estimate(115, 190);
        assert_eq!(whole.bytes, 90_000_000.0);
        assert!((whole.bytes - first.bytes - second.bytes).abs() < 0.000_01);
        assert_eq!(first.seconds + second.seconds, 180.0);
        Ok(())
    }

    #[test]
    fn chart_buckets_clip_both_edges_and_preserve_independent_direction_coverage() -> CmdResult<()> {
        let inbound = Readings::from_values((1..=6).map(|index| (f64::from(index * 20), "2".into())).collect())?;
        let outbound = Readings::from_values(vec![(100.0, "0".into()), (120.0, "0".into())])?;
        let buckets = bandwidth_buckets(&inbound, &outbound, 30, 110, 100);
        let [first, last] = buckets.as_slice() else {
            return Err(invalid_response());
        };
        assert_eq!((first.start, first.until), (30, 100));
        assert_eq!((last.start, last.until), (100, 110));
        assert_eq!(
            (first.inbound_bytes, first.inbound_covered_seconds),
            (Some(17_500_000.0), 70.0)
        );
        assert_eq!((first.outbound_bytes, first.outbound_covered_seconds), (None, 0.0));
        assert_eq!(
            (last.inbound_bytes, last.inbound_covered_seconds),
            (Some(2_500_000.0), 10.0)
        );
        assert_eq!((last.outbound_bytes, last.outbound_covered_seconds), (Some(0.0), 10.0));
        let total = buckets.iter().filter_map(|bucket| bucket.inbound_bytes).sum::<f64>();
        assert_eq!(inbound.series(30, 110).estimated_bytes, Some(total));
        Ok(())
    }

    #[test]
    fn finite_zero_is_distinct_from_missing_and_conflicting_duplicates() -> CmdResult<()> {
        assert_eq!(Readings::default().series(0, 60).estimated_bytes, None);
        let zero = Readings::from_values(vec![(0.0, "0".into()), (60.0, "0".into())])?.series(0, 60);
        assert_eq!(zero.estimated_bytes, Some(0.0));
        assert_eq!(zero.covered_seconds, 60.0);
        let conflict = Readings::from_values(vec![(0.0, "1".into()), (0.0, "2".into())]);
        assert!(conflict.is_err());
        Ok(())
    }

    #[test]
    fn monthly_quota_handles_utc_and_refuses_to_infer_unobserved_traffic() -> CmdResult<()> {
        let now = Utc
            .with_ymd_and_hms(2026, 12, 31, 0, 0, 0)
            .single()
            .ok_or_else(invalid_response)?;
        let (start, end) = month_bounds(now)?;
        assert_eq!(end - start, 31 * DAY);
        assert_eq!(end, 1_798_761_600); // 2027-01-01 00:00:00 UTC
        let ordinary = Plan::from_size(Size {
            slug: "s-1vcpu-1gb".into(),
            transfer: 1.0,
        })
        .ok_or_else(invalid_response)?;
        let v5 = Plan::from_size(Size {
            slug: "s5-2vcpu-4gb".into(),
            transfer: 1.0,
        })
        .ok_or_else(invalid_response)?;
        assert_eq!(ordinary.allowance(31 * DAY), 1_000.0);
        assert!(v5.allowance(31 * DAY) > 1_100.0);

        let first = start + 10 * DAY;
        let now = start + 17 * DAY;
        let incomplete = monthly_summary(
            start,
            end,
            now,
            first,
            Some(ordinary),
            Estimate {
                bytes: 2.0 * GIB,
                seconds: 120.0,
            },
        );
        assert_eq!(incomplete.outbound_gib, Some(2.0));
        assert_eq!(incomplete.accrued_gib, Some(250.0));
        assert_eq!(incomplete.projected_allowance_gib, Some(750.0));
        assert_eq!(incomplete.remaining_gib, None);
        let complete = monthly_summary(
            start,
            end,
            now,
            first,
            Some(v5),
            Estimate {
                bytes: 800.0 * GIB,
                seconds: (7 * DAY) as f64,
            },
        );
        assert_eq!(complete.remaining_gib, Some(-50.0));
        assert_eq!(complete.coverage, Some(1.0));
        Ok(())
    }

    #[test]
    fn pagination_uses_provider_links_only_as_continuation_signals() -> CmdResult<()> {
        let parse = |value| serde_json::from_value::<DropletList>(value).map_err(|_| invalid_response());
        let response =
            parse(json!({ "droplets": [], "links": { "pages": { "next": "https://untrusted.invalid/" } } }))?;
        assert!(response.has_more(1, 200));
        let response = parse(json!({ "droplets": [], "meta": { "total": 201 } }))?;
        assert!(response.has_more(1, 200));
        assert!(!response.has_more(2, 200));
        Ok(())
    }
}
