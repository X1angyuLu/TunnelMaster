use crate::{
    config::{IVerge, MixedPort},
    utils::server,
};
use anyhow::{Result, ensure};
use clash_verge_service_ipc::{
    MacosProxyConfig,
    proxy_ownership::{auto_discovery_enabled, owns_snapshot},
};
use parking_lot::Mutex;

static LAST_PROXY: Mutex<Option<MacosProxyConfig>> = Mutex::new(None);

pub fn forget_proxy() {
    *LAST_PROXY.lock() = None;
}

pub async fn note_enabled_proxy(verge: &IVerge) -> Result<()> {
    let target = if verge.proxy_auto_config.unwrap_or_default() {
        MacosProxyConfig::Pac {
            url: format!("http://127.0.0.1:{}/commands/pac", server::embedded_server_port()?),
        }
    } else {
        MacosProxyConfig::Global {
            host: verge.proxy_host.as_deref().unwrap_or("127.0.0.1").to_owned(),
            port: MixedPort::desired().await,
            bypass: String::new(),
        }
    };
    *LAST_PROXY.lock() = Some(target);
    Ok(())
}

pub async fn check_proxy(enable: bool) -> Result<bool> {
    tokio::task::spawn_blocking(move || {
        let snapshot = match sysproxy::Sysproxy::snapshot() {
            Ok(snapshot) => snapshot,
            Err(sysproxy::Error::NoActiveNetworkService | sysproxy::Error::NetworkInterface) => return Ok(enable),
            Err(error) => return Err(error.into()),
        };
        let discovery = auto_discovery_enabled()?;
        let mut last = LAST_PROXY.lock();
        let own = !discovery && last.as_ref().is_some_and(|previous| owns_snapshot(&snapshot, previous));
        if !own {
            *last = None;
        }
        if !enable {
            return Ok(own);
        }
        ensure!(
            own || (!discovery && snapshot.is_all_disabled()),
            "Another application controls the macOS system proxy"
        );
        Ok(true)
    })
    .await?
}

pub async fn check_tun() -> Result<()> {
    // TUN can otherwise capture the old application's socket and break its route.
    check_proxy(true).await?;
    for (family, target) in [
        ("-inet", "1.1.1.1"),
        ("-inet", "9.9.9.9"),
        ("-inet6", "2606:4700:4700::1111"),
    ] {
        ensure!(
            !route_interface(family, target)
                .await?
                .is_some_and(|name| name.starts_with("utun")),
            "Another VPN already controls the default internet route"
        );
    }
    Ok(())
}

pub async fn route_interface(family: &str, target: &str) -> Result<Option<String>> {
    let output = tokio::time::timeout(
        std::time::Duration::from_secs(2),
        tokio::process::Command::new("/sbin/route")
            .args(["-n", "get", family, target])
            .kill_on_drop(true)
            .output(),
    )
    .await??;
    if !output.status.success() {
        return Ok(None);
    }
    let route = String::from_utf8_lossy(&output.stdout);
    Ok(route.lines().find_map(|line| {
        line.trim_start()
            .strip_prefix("interface:")
            .map(|name| name.trim().to_owned())
    }))
}
