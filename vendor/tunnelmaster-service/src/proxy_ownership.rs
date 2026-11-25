use crate::MacosProxyConfig;
use sysproxy::ProxySnapshot;

/// Handles partial writes without mistaking a mixture of our endpoints and a
/// third-party proxy for an owned setting.
pub fn owns_snapshot(snapshot: &ProxySnapshot, candidate: &MacosProxyConfig) -> bool {
    match candidate {
        MacosProxyConfig::Disabled => false,
        MacosProxyConfig::Global { host, port, .. } => {
            let endpoints = [&snapshot.http, &snapshot.https, &snapshot.socks];
            !snapshot.auto_switched_on
                && endpoints.iter().any(|endpoint| endpoint.switched_on)
                && endpoints.iter().all(|endpoint| {
                    !endpoint.switched_on || (endpoint.enable && &endpoint.host == host && endpoint.port == *port)
                })
        }
        MacosProxyConfig::Pac { url } => {
            snapshot.auto_switched_on
                && snapshot.auto.enable
                && snapshot.auto.url == *url
                && !snapshot.http.switched_on
                && !snapshot.https.switched_on
                && !snapshot.socks.switched_on
        }
    }
}

/// The proxy library models explicit PAC and endpoints only, while macOS also
/// supports a separate WPAD discovery switch.
pub fn auto_discovery_enabled() -> std::io::Result<bool> {
    let output = std::process::Command::new("/usr/sbin/scutil").arg("--proxy").output()?;
    if !output.status.success() {
        return Err(std::io::Error::other("Unable to inspect macOS proxy discovery"));
    }
    Ok(String::from_utf8_lossy(&output.stdout).lines().any(|line| {
        line.split_once(':')
            .is_some_and(|(name, value)| name.trim() == "ProxyAutoDiscoveryEnable" && value.trim() == "1")
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_mixed_proxy_never_belongs_to_us() {
        let ours = MacosProxyConfig::Global {
            host: "127.0.0.1".into(),
            port: 17897,
            bypass: String::new(),
        };
        let endpoint = sysproxy::ProxyEndpoint {
            host: "127.0.0.1".into(),
            port: 17897,
            enable: true,
            switched_on: true,
        };
        let mut snapshot = ProxySnapshot {
            http: endpoint.clone(),
            https: endpoint,
            ..ProxySnapshot::default()
        };
        assert!(owns_snapshot(&snapshot, &ours));
        snapshot.https.port = 7897;
        assert!(!owns_snapshot(&snapshot, &ours));
        snapshot.https = sysproxy::ProxyEndpoint::default();
        snapshot.auto_switched_on = true;
        assert!(!owns_snapshot(&snapshot, &ours));
    }
}
