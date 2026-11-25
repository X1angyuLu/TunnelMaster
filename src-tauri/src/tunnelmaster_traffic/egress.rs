use crate::{
    cmd::{CmdResult, CommandFailure},
    config::MixedPort,
    core::CoreManager,
};
use serde::Serialize;
use specta::Type;
use std::{net::IpAddr, time::Duration};

const TRACE: &str = "https://www.cloudflare.com/cdn-cgi/trace";
const MAX_TRACE_BYTES: usize = 8 * 1024;

#[derive(Serialize, Type)]
pub struct EgressProbe {
    ip: String,
    country: Option<String>,
}

#[tauri::command]
#[specta::specta]
pub async fn probe_tunnelmaster_egress() -> CmdResult<EgressProbe> {
    let core = CoreManager::global();
    let generation = core
        .current_core_readiness_generation()
        .ok_or_else(|| CommandFailure::plain("Mihomo has not started"))?;
    let port = MixedPort::effective().await;
    let proxy = reqwest::Proxy::all(format!("http://127.0.0.1:{port}")).map_err(CommandFailure::plain)?;
    let client = reqwest::Client::builder()
        .no_proxy()
        .proxy(proxy)
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(8))
        .build()
        .map_err(CommandFailure::plain)?;
    let mut response = client
        .get(TRACE)
        .send()
        .await
        .and_then(reqwest::Response::error_for_status)
        .map_err(|_| CommandFailure::plain("Could not reach Cloudflare through the current Mihomo rules"))?;
    let mut contents = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(CommandFailure::plain)? {
        if contents.len().saturating_add(chunk.len()) > MAX_TRACE_BYTES {
            return Err(CommandFailure::plain("Cloudflare returned an unexpectedly large trace"));
        }
        contents.extend_from_slice(&chunk);
    }
    if core.current_core_readiness_generation() != Some(generation) {
        return Err(CommandFailure::plain("Mihomo changed during the check. Try again."));
    }
    let trace = std::str::from_utf8(&contents).map_err(CommandFailure::plain)?;
    parse_trace(trace).ok_or_else(|| CommandFailure::plain("Cloudflare did not report an exit IP"))
}

fn parse_trace(trace: &str) -> Option<EgressProbe> {
    let field = |name| {
        trace.lines().find_map(|line| {
            let (key, value) = line.split_once('=')?;
            (key == name).then_some(value.trim())
        })
    };
    let ip = field("ip")?.parse::<IpAddr>().ok()?.to_string();
    let country = field("loc")
        .filter(|value| value.len() == 2 && value.bytes().all(|byte| byte.is_ascii_uppercase()))
        .map(str::to_owned);
    Some(EgressProbe { ip, country })
}

#[cfg(test)]
mod tests {
    use super::parse_trace;

    #[test]
    fn exit_trace_extracts_only_a_valid_ip_and_country() {
        let report = parse_trace("h=example.com\nip=2001:db8::1\nloc=HK\n").unwrap();
        assert_eq!(report.ip, "2001:db8::1");
        assert_eq!(report.country.as_deref(), Some("HK"));
        assert!(parse_trace("ip=token-like-garbage\nloc=HK").is_none());
        assert!(parse_trace("ip=192.0.2.1\nloc=---").unwrap().country.is_none());
    }
}
