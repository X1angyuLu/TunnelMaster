use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};
use serde_yaml_ng::{Mapping, Value, to_value};
use std::{collections::HashSet, net::IpAddr};

use super::wireguard::WIREGUARD;

const PREFERENCES: &str = "x-tunnelmaster-rules";
const LOCAL_RULES: &[&str] = &[
    "DOMAIN,localhost,DIRECT",
    "DOMAIN-SUFFIX,local,DIRECT",
    "DOMAIN-SUFFIX,home.arpa,DIRECT",
    "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
    "IP-CIDR,100.64.0.0/10,DIRECT,no-resolve",
    "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
    "IP-CIDR,169.254.0.0/16,DIRECT,no-resolve",
    "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
    "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
    "IP-CIDR6,::1/128,DIRECT,no-resolve",
    "IP-CIDR6,fc00::/7,DIRECT,no-resolve",
    "IP-CIDR6,fe80::/10,DIRECT,no-resolve",
];
pub(super) const NATIVE_DIRECT_DOMAINS: &[&str] = &[
    "bilibili.com",
    "hdslb.com",
    "taobao.com",
    "tmall.com",
    "alicdn.com",
    "jd.com",
    "jdcloud.com",
    "qq.com",
    "weixin.qq.com",
];
const EXTRA_DIRECT_DOMAINS: &[&str] = &["xiaohongshu.com", "xhscdn.com", "xhslink.com", "rednote.com"];
pub(super) const AI_DOMAINS: &[&str] = &[
    "openai.com",
    "chatgpt.com",
    "oaistatic.com",
    "oaiusercontent.com",
    "oaistatsig.com",
    "anthropic.com",
    "claude.ai",
    "claude.com",
    "claudeusercontent.com",
];

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize, specta::Type)]
#[serde(rename_all = "lowercase")]
pub enum UnmatchedTraffic {
    Direct,
    Wireguard,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct TunnelMasterRules {
    pub direct_domains: Vec<String>,
    pub proxy_domains: Vec<String>,
    pub china_ip_direct: bool,
    pub unmatched: UnmatchedTraffic,
}

impl Default for TunnelMasterRules {
    fn default() -> Self {
        Self {
            direct_domains: NATIVE_DIRECT_DOMAINS
                .iter()
                .chain(EXTRA_DIRECT_DOMAINS)
                .map(|domain| (*domain).to_owned())
                .collect(),
            proxy_domains: AI_DOMAINS.iter().map(|domain| (*domain).to_owned()).collect(),
            china_ip_direct: true,
            unmatched: UnmatchedTraffic::Direct,
        }
    }
}

impl TunnelMasterRules {
    fn normalize(self) -> Result<Self> {
        Ok(Self {
            direct_domains: normalize_domains(self.direct_domains)?,
            proxy_domains: normalize_domains(self.proxy_domains)?,
            ..self
        })
    }

    fn generated(&self) -> Vec<String> {
        let mut rules = Vec::new();
        rules.extend(
            self.proxy_domains
                .iter()
                .map(|domain| format!("DOMAIN-SUFFIX,{domain},{WIREGUARD}")),
        );
        rules.extend(
            self.direct_domains
                .iter()
                .map(|domain| format!("DOMAIN-SUFFIX,{domain},DIRECT")),
        );
        rules.extend(LOCAL_RULES.iter().map(|rule| (*rule).to_owned()));
        if self.china_ip_direct {
            rules.push("GEOIP,CN,DIRECT".to_owned());
        }
        rules.push(match self.unmatched {
            UnmatchedTraffic::Direct => "MATCH,DIRECT".to_owned(),
            UnmatchedTraffic::Wireguard => format!("MATCH,{WIREGUARD}"),
        });
        rules
    }

    fn dns_policy(&self, config: &Mapping) -> Mapping {
        if self.unmatched != UnmatchedTraffic::Direct || self.proxy_domains.is_empty() {
            return Mapping::new();
        }
        let Some(servers) = config
            .get("proxies")
            .and_then(Value::as_sequence)
            .and_then(|proxies| {
                proxies
                    .iter()
                    .find(|proxy| proxy.get("name").and_then(Value::as_str) == Some(WIREGUARD))
            })
            .and_then(|proxy| proxy.get("dns"))
            .and_then(Value::as_sequence)
        else {
            return Mapping::new();
        };
        let resolvers = Value::Sequence(
            servers
                .iter()
                .filter_map(Value::as_str)
                .map(|server| {
                    let resolver = match server.parse::<IpAddr>() {
                        Ok(IpAddr::V4(_)) => format!("udp://{server}:53#{WIREGUARD}"),
                        Ok(IpAddr::V6(_)) => format!("udp://[{server}]:53#{WIREGUARD}"),
                        Err(_) => format!("{server}#{WIREGUARD}"),
                    };
                    Value::from(resolver)
                })
                .collect(),
        );
        if resolvers.as_sequence().is_none_or(Vec::is_empty) {
            return Mapping::new();
        }
        self.proxy_domains
            .iter()
            .map(|domain| (Value::from(format!("+.{domain}")), resolvers.clone()))
            .collect()
    }
}

fn normalize_domains(input: Vec<String>) -> Result<Vec<String>> {
    if input.len() > 512 {
        bail!("Use at most 512 domains in each routing list.");
    }
    let mut seen = HashSet::new();
    let mut result = Vec::new();
    for text in input {
        let text = text.trim();
        let domain = text
            .strip_prefix("*.")
            .or_else(|| text.strip_prefix('.'))
            .unwrap_or(text);
        let domain = domain.strip_suffix('.').unwrap_or(domain).to_ascii_lowercase();
        if !valid_dns_name(&domain, true) || domain.parse::<IpAddr>().is_ok() {
            bail!("Routing entries must be domain names without URLs, ports, or paths.");
        }
        if seen.insert(domain.clone()) {
            result.push(domain);
        }
    }
    Ok(result)
}

pub(super) fn valid_dns_name(domain: &str, require_dot: bool) -> bool {
    domain.len() <= 253
        && (!require_dot || domain.contains('.'))
        && domain.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
}

fn read_config(yaml: &str) -> Result<Mapping> {
    serde_yaml_ng::from_str(yaml).map_err(|_| anyhow::anyhow!("The local WireGuard profile is not valid YAML."))
}

fn preferences(config: &Mapping) -> Result<TunnelMasterRules> {
    let Some(existing) = config.get(PREFERENCES) else {
        bail!("The profile no longer contains TunnelMaster rule settings.");
    };
    let rules: TunnelMasterRules = serde_yaml_ng::from_value(existing.clone())
        .map_err(|_| anyhow::anyhow!("The profile's TunnelMaster rule settings are invalid."))?;
    rules.normalize()
}

pub(super) fn read_preferences(yaml: &str) -> Result<TunnelMasterRules> {
    preferences(&read_config(yaml)?)
}

pub(super) fn new_profile(proxy: serde_json::Value, rules: TunnelMasterRules) -> Result<String> {
    let rules = rules.normalize()?;
    let ipv6 = proxy.get("ipv6").is_some();
    let groups = serde_json::json!([{"name": "TunnelMaster", "type": "select", "proxies": [WIREGUARD, "DIRECT"]}]);
    let mut config = Mapping::new();
    config.insert("mode".into(), "rule".into());
    config.insert("ipv6".into(), ipv6.into());
    config.insert("proxies".into(), to_value(vec![proxy])?);
    config.insert("proxy-groups".into(), to_value(groups)?);
    write_prefs(&mut config, None, &rules)?;
    serde_yaml_ng::to_string(&config).map_err(|_| anyhow::anyhow!("Could not generate the WireGuard profile."))
}

pub(super) fn replace_rules(yaml: &str, next: TunnelMasterRules) -> Result<Option<String>> {
    let next = next.normalize()?;
    let mut config = read_config(yaml)?;
    let previous = preferences(&config)?;
    if previous == next {
        return Ok(None);
    }
    write_prefs(&mut config, Some(&previous), &next)?;
    serde_yaml_ng::to_string(&config)
        .map(Some)
        .map_err(|_| anyhow::anyhow!("Could not save the WireGuard rule settings."))
}

fn write_prefs(config: &mut Mapping, previous: Option<&TunnelMasterRules>, next: &TunnelMasterRules) -> Result<()> {
    let mut old_rules: HashSet<String> = previous
        .map(TunnelMasterRules::generated)
        .unwrap_or_default()
        .into_iter()
        .collect();
    let mut updated = match config.remove("rules") {
        Some(Value::Sequence(rules)) => rules
            .into_iter()
            .filter(|rule| !rule.as_str().is_some_and(|text| old_rules.remove(text)))
            .collect(),
        None => Vec::new(),
        _ => bail!("This profile's rules must be a YAML list."),
    };
    updated.extend(next.generated().into_iter().map(Value::from));
    config.insert("rules".into(), Value::Sequence(updated));

    let old_policy = previous.map(|rules| rules.dns_policy(config)).unwrap_or_default();
    let policy = next.dns_policy(config);
    if !old_policy.is_empty() || !policy.is_empty() {
        let ipv6 = config.get("ipv6").and_then(Value::as_bool).unwrap_or(false);
        let dns = config
            .entry("dns".into())
            .or_insert_with(|| Value::Mapping(default_dns(ipv6)));
        let Some(dns) = dns.as_mapping_mut() else {
            bail!("This profile's DNS settings must be a YAML mapping.");
        };
        let policies = dns
            .entry("nameserver-policy".into())
            .or_insert_with(|| Value::Mapping(Mapping::new()));
        let Some(policies) = policies.as_mapping_mut() else {
            bail!("This profile's DNS policy must be a YAML mapping.");
        };
        for (domain, value) in old_policy {
            if policies.get(&domain) == Some(&value) {
                policies.remove(&domain);
            }
        }
        for (domain, value) in policy {
            policies.entry(domain).or_insert(value);
        }
    }
    config.insert(PREFERENCES.into(), to_value(next)?);
    Ok(())
}

fn default_dns(ipv6: bool) -> Mapping {
    let resolver = Value::Sequence(vec!["system".into()]);
    [
        ("enable", true.into()),
        ("enhanced-mode", "redir-host".into()),
        ("ipv6", ipv6.into()),
        ("nameserver", resolver.clone()),
        ("direct-nameserver", resolver.clone()),
        ("proxy-server-nameserver", resolver),
    ]
    .into_iter()
    .map(|(key, value)| (key.into(), value))
    .collect()
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn updates_presets_without_removing_custom_rules_or_dns() -> Result<()> {
        let yaml = new_profile(
            json!({"name": "WireGuard", "dns": ["192.0.2.53"]}),
            TunnelMasterRules::default(),
        )?;
        let mut config = read_config(&yaml)?;
        let Some(values) = config.get_mut("rules").and_then(Value::as_sequence_mut) else {
            bail!("generated profile did not contain rules");
        };
        values.insert(0, "DOMAIN,overridden.example,REJECT".into());
        let Some(policy) = config
            .get_mut("dns")
            .and_then(Value::as_mapping_mut)
            .and_then(|dns| dns.get_mut("nameserver-policy"))
            .and_then(Value::as_mapping_mut)
        else {
            bail!("generated profile did not contain DNS policies");
        };
        policy.insert("+.openai.com".into(), "custom-resolver".into());

        let rules = TunnelMasterRules {
            direct_domains: vec!["*.xiaohongshu.com".into(), "XIAOHONGSHU.COM.".into()],
            proxy_domains: vec!["openai.com".into()],
            china_ip_direct: false,
            unmatched: UnmatchedTraffic::Wireguard,
        };
        let yaml = replace_rules(&serde_yaml_ng::to_string(&config)?, rules)?.unwrap();
        let updated = read_config(&yaml)?;
        let lines = updated["rules"].as_sequence().unwrap();
        assert_eq!(
            lines.first().and_then(Value::as_str),
            Some("DOMAIN,overridden.example,REJECT")
        );
        assert_eq!(lines.last().and_then(Value::as_str), Some("MATCH,WireGuard"));
        assert!(!lines.iter().any(|rule| rule.as_str() == Some("GEOIP,CN,DIRECT")));
        assert_eq!(
            updated["dns"]["nameserver-policy"]["+.openai.com"].as_str(),
            Some("custom-resolver")
        );
        assert_eq!(read_preferences(&yaml)?.direct_domains, vec!["xiaohongshu.com"]);
        Ok(())
    }
}
