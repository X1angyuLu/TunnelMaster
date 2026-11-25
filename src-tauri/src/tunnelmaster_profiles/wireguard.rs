use anyhow::{Result, bail};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::{collections::HashMap, net::IpAddr};

use super::rules::valid_dns_name;

pub(super) const WIREGUARD: &str = "WireGuard";

pub(super) fn parse(input: &str) -> Result<Value> {
    let mut interface = None;
    let mut peer = None;
    let mut in_peer = false;
    for raw in input.trim_start_matches('\u{feff}').lines() {
        let line = raw.split_once('#').map_or(raw, |(value, _)| value).trim();
        if line.is_empty() || line.starts_with(';') {
            continue;
        }
        if line.eq_ignore_ascii_case("[Interface]") && interface.is_none() && peer.is_none() {
            interface = Some(HashMap::<String, String>::new());
            continue;
        }
        if line.eq_ignore_ascii_case("[Peer]") && interface.is_some() && peer.is_none() {
            peer = Some(HashMap::<String, String>::new());
            in_peer = true;
            continue;
        }
        if line.starts_with('[') {
            bail!("WireGuard import requires one [Interface] followed by one [Peer].");
        }

        let Some((name, value)) = line.split_once('=') else {
            bail!("A WireGuard setting must have a name and a value.");
        };
        let Some(fields) = (if in_peer { peer.as_mut() } else { interface.as_mut() }) else {
            bail!("WireGuard settings must be inside [Interface] or [Peer].");
        };
        let name = name.trim().to_ascii_lowercase();
        let value = value.trim();
        if name.is_empty() || value.is_empty() {
            bail!("A WireGuard setting must have a name and a value.");
        }
        // wg-quick options and shell hooks do not belong to a Mihomo outbound.
        if !supported_field(in_peer, &name) {
            continue;
        }
        if let Some(previous) = fields.get_mut(&name) {
            if !matches!(name.as_str(), "address" | "allowedips" | "dns") {
                bail!("A WireGuard setting occurs more than once.");
            }
            previous.push(',');
            previous.push_str(value);
        } else {
            fields.insert(name, value.to_owned());
        }
    }

    let (Some(interface), Some(peer)) = (interface, peer) else {
        bail!("WireGuard import requires one [Interface] followed by one [Peer].");
    };

    let mut ipv4 = None;
    let mut ipv6 = None;
    for address in split_list(interface.get("address")) {
        let (ip, _) = parse_prefix(address)?;
        let stored = if ip.is_ipv4() { &mut ipv4 } else { &mut ipv6 };
        if stored.replace(ip.to_string()).is_some() {
            bail!("Use at most one IPv4 and one IPv6 interface address.");
        }
    }
    if ipv4.is_none() && ipv6.is_none() {
        bail!("The WireGuard interface needs an IPv4 or IPv6 address.");
    }

    let mut allowed = Vec::new();
    let mut full_ipv4 = false;
    let mut full_ipv6 = false;
    for address in split_list(peer.get("allowedips")) {
        let (ip, prefix) = parse_prefix(address)?;
        full_ipv4 |= ip.is_ipv4() && prefix == 0;
        full_ipv6 |= ip.is_ipv6() && prefix == 0;
        let cidr = format!("{ip}/{prefix}");
        if !allowed.contains(&cidr) {
            allowed.push(cidr);
        }
    }
    if allowed.is_empty() {
        bail!("The WireGuard peer needs at least one AllowedIPs entry.");
    }

    let (host, port) = parse_endpoint(peer.get("endpoint").map(String::as_str))?;
    let private_key = parse_key(interface.get("privatekey"))?;
    let public_key = parse_key(peer.get("publickey"))?;
    let mut proxy = json!({
        "name": WIREGUARD,
        "type": "wireguard",
        "server": host,
        "port": port,
        "private-key": private_key,
        "public-key": public_key,
        "allowed-ips": allowed,
        "udp": true,
        "ip-version": if ipv4.is_some() { "ipv4-prefer" } else { "ipv6" },
    });
    if let Some(ref address) = ipv4 {
        proxy["ip"] = json!(address);
    }
    if let Some(ref address) = ipv6 {
        proxy["ipv6"] = json!(address);
    }
    if peer.contains_key("presharedkey") {
        proxy["pre-shared-key"] = json!(parse_key(peer.get("presharedkey"))?);
    }
    if let Some(mtu) = interface.get("mtu") {
        let Some(mtu) = mtu.parse::<u16>().ok().filter(|value| *value >= 576) else {
            bail!("The WireGuard MTU must be between 576 and 65535.");
        };
        proxy["mtu"] = json!(mtu);
    }
    if let Some(keepalive) = peer.get("persistentkeepalive") {
        let keepalive = if keepalive.eq_ignore_ascii_case("off") {
            0
        } else {
            let Ok(value) = keepalive.parse::<u16>() else {
                bail!("PersistentKeepalive must be off or a number between 0 and 65535.");
            };
            value
        };
        proxy["persistent-keepalive"] = json!(keepalive);
    }

    let mut servers: Vec<String> = split_list(interface.get("dns"))
        .filter_map(|value| value.parse::<IpAddr>().ok().map(|ip| ip.to_string()))
        .collect();
    if servers.is_empty() {
        // Bootstrap the encrypted resolver only through a route the peer actually carries.
        if ipv4.is_some() && full_ipv4 {
            servers.push("https://1.1.1.1/dns-query".to_owned());
        } else if ipv6.is_some() && full_ipv6 {
            servers.push("https://[2606:4700:4700::1111]/dns-query".to_owned());
        }
    }
    if !servers.is_empty() {
        proxy["remote-dns-resolve"] = json!(true);
        proxy["dns"] = json!(servers);
    }
    Ok(proxy)
}

fn supported_field(in_peer: bool, name: &str) -> bool {
    if in_peer {
        matches!(
            name,
            "publickey" | "presharedkey" | "allowedips" | "endpoint" | "persistentkeepalive"
        )
    } else {
        matches!(name, "privatekey" | "address" | "dns" | "mtu")
    }
}

fn split_list(value: Option<&String>) -> impl Iterator<Item = &str> {
    value.into_iter().flat_map(|value| value.split(',').map(str::trim))
}

fn parse_prefix(value: &str) -> Result<(IpAddr, u8)> {
    let (address, prefix) = value
        .split_once('/')
        .map_or((value, None), |(ip, prefix)| (ip, Some(prefix)));
    let Ok(ip) = address.parse::<IpAddr>() else {
        bail!("A WireGuard interface address or AllowedIPs entry is invalid.");
    };
    let maximum = if ip.is_ipv4() { 32 } else { 128 };
    let prefix = match prefix {
        None => maximum,
        Some(prefix) => match prefix.parse::<u8>() {
            Ok(prefix) if prefix <= maximum => prefix,
            _ => bail!("A WireGuard address prefix is invalid."),
        },
    };
    Ok((ip, prefix))
}

fn parse_endpoint(endpoint: Option<&str>) -> Result<(&str, u16)> {
    let Some((host, port)) = endpoint.and_then(|value| value.rsplit_once(':')) else {
        bail!("The WireGuard peer needs an endpoint in host:port format.");
    };
    let host = if let Some(host) = host.strip_prefix('[').and_then(|value| value.strip_suffix(']')) {
        if host.parse::<std::net::Ipv6Addr>().is_err() {
            bail!("A bracketed WireGuard endpoint must use a valid IPv6 address.");
        }
        host
    } else {
        if host.parse::<std::net::Ipv4Addr>().is_err() && !valid_dns_name(host.trim_end_matches('.'), false) {
            bail!("The WireGuard endpoint host is invalid.");
        }
        host
    };
    let Some(port) = port.parse::<u16>().ok().filter(|port| *port > 0) else {
        bail!("The WireGuard endpoint port must be between 1 and 65535.");
    };
    Ok((host, port))
}

fn parse_key(value: Option<&String>) -> Result<&str> {
    if let Some(value) = value
        && let Ok(bytes) = STANDARD.decode(value)
        && bytes.len() == 32
        && STANDARD.encode(bytes) == *value
    {
        return Ok(value);
    }
    bail!("WireGuard keys must use canonical base64 encoding for exactly 32 bytes.");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_both_ip_families_without_importing_shell_hooks() -> Result<()> {
        let key = STANDARD.encode([7u8; 32]);
        let config = format!(
            "\u{feff}[Interface]\r\nPrivateKey = {key}\r\nAddress = 192.0.2.2/32\r\nAddress = 2001:db8::2/128\r\nPostUp = ignored\r\n[Peer]\r\nPublicKey = {key}\r\nEndpoint = [2001:db8::1]:51820\r\nAllowedIPs = ::/0,0.0.0.0/0\r\n"
        );
        let parsed = parse(&config)?;
        assert_eq!(parsed["server"], "2001:db8::1");
        assert_eq!(parsed["ip"], "192.0.2.2");
        assert_eq!(parsed["ipv6"], "2001:db8::2");
        assert!(parsed.get("PostUp").is_none());
        assert!(parse(&format!("{config}[Peer]\n")).is_err());
        let error = parse(&config.replace(&key, "private-fixture-input"))
            .unwrap_err()
            .to_string();
        assert!(!error.contains("private-fixture-input"));
        Ok(())
    }
}
