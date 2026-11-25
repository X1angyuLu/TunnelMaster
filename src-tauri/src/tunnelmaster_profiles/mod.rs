#[cfg(target_os = "macos")]
mod legacy;
mod rules;
mod wireguard;

use crate::{
    cmd::{CmdResult, coded_error, save_profile::transform_profile_file},
    config::{Config, profiles::append_tunnelmaster_wireguard},
    core::{
        notify::{Refresh, announce},
        validate::ValidationOutcome,
    },
};
use anyhow::{Result, bail};
use std::path::Path;
use tokio::io::AsyncReadExt as _;

use rules::TunnelMasterRules;

const MAX_CONF_SIZE: usize = 128 * 1024;
pub(crate) const WIREGUARD_PROFILE_PREFIX: &str = "Ltmwg-";

#[tauri::command]
#[specta::specta]
pub async fn import_tunnelmaster_wireguard() -> CmdResult<Option<String>> {
    let Some(selection) = rfd::AsyncFileDialog::new()
        .set_title("Import WireGuard configuration")
        .add_filter("WireGuard configuration", &["conf"])
        .pick_file()
        .await
    else {
        return Ok(None);
    };
    let path = selection.path();
    let source = read_wireguard_file(path)
        .await
        .map_err(|error| coded_error("WIREGUARD_IMPORT_FAILED", error))?;
    let name = path.file_stem().and_then(|name| name.to_str()).unwrap_or("WireGuard");
    add_wireguard_profile(&source, name, TunnelMasterRules::default(), "WIREGUARD_IMPORT_FAILED")
        .await
        .map(Some)
}

#[tauri::command]
#[specta::specta]
pub async fn migrate_native_tunnelmaster_profile() -> CmdResult<String> {
    #[cfg(target_os = "macos")]
    {
        let legacy::NativeProfile { source, name, rules } = tokio::task::spawn_blocking(legacy::read_native_profile)
            .await
            .map_err(|_| {
                coded_error(
                    "NATIVE_WIREGUARD_IMPORT_FAILED",
                    "Could not read the native TunnelMaster profile.",
                )
            })??;
        add_wireguard_profile(&source, &name, rules, "NATIVE_WIREGUARD_IMPORT_FAILED").await
    }
    #[cfg(not(target_os = "macos"))]
    Err(coded_error(
        "NATIVE_WIREGUARD_IMPORT_UNAVAILABLE",
        "The native TunnelMaster profile can be imported on macOS.",
    ))
}

async fn add_wireguard_profile(
    source: &str,
    name: &str,
    rules: TunnelMasterRules,
    error_code: &str,
) -> CmdResult<String> {
    let proxy = wireguard::parse(source).map_err(|error| coded_error(error_code, error))?;
    let yaml = rules::new_profile(proxy, rules).map_err(|error| coded_error(error_code, error))?;
    let name: String = name.chars().filter(|ch| !ch.is_control()).take(80).collect();
    let name = if name.trim().is_empty() {
        "WireGuard".to_owned()
    } else {
        name
    };
    let uid = append_tunnelmaster_wireguard(name, &yaml)
        .await
        .map_err(|_| coded_error(error_code, "Could not save the local WireGuard profile."))?;
    announce(Refresh::Profiles);
    Ok(uid.into())
}

#[tauri::command]
#[specta::specta]
pub async fn get_tunnelmaster_rules(index: String) -> CmdResult<Option<TunnelMasterRules>> {
    if !index.starts_with(WIREGUARD_PROFILE_PREFIX) {
        return Ok(None);
    }
    let item = Config::profiles()
        .await
        .data_arc()
        .get_item(&index)
        .map_err(|_| {
            coded_error(
                "TUNNELMASTER_RULES_READ_FAILED",
                "The local WireGuard profile no longer exists.",
            )
        })?
        .clone();
    let source = item.read_file().await.map_err(|_| {
        coded_error(
            "TUNNELMASTER_RULES_READ_FAILED",
            "Could not read the local WireGuard profile.",
        )
    })?;
    rules::read_preferences(&source)
        .map(Some)
        .map_err(|error| coded_error("TUNNELMASTER_RULES_READ_FAILED", error))
}

#[tauri::command]
#[specta::specta]
pub async fn save_tunnelmaster_rules(index: String, rules: TunnelMasterRules) -> CmdResult<ValidationOutcome> {
    if !index.starts_with(WIREGUARD_PROFILE_PREFIX) {
        return Err(coded_error(
            "TUNNELMASTER_RULES_SAVE_FAILED",
            "Select a profile imported from WireGuard.",
        ));
    }
    transform_profile_file(index.into(), |source| {
        rules::replace_rules(source, rules)
            .map(|value| value.map(Into::into))
            .map_err(|error| coded_error("TUNNELMASTER_RULES_SAVE_FAILED", error))
    })
    .await
}

async fn read_wireguard_file(path: &Path) -> Result<String> {
    if !path
        .extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| ext.eq_ignore_ascii_case("conf"))
    {
        bail!("Choose a WireGuard .conf file.");
    }
    let mut options = tokio::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    options.custom_flags(libc::O_NONBLOCK);
    let file = options
        .open(path)
        .await
        .map_err(|_| anyhow::anyhow!("Could not open the selected WireGuard file."))?;
    let metadata = file
        .metadata()
        .await
        .map_err(|_| anyhow::anyhow!("Could not inspect the selected WireGuard file."))?;
    if !metadata.is_file() || metadata.len() > MAX_CONF_SIZE as u64 {
        bail!("The WireGuard configuration must be a regular file no larger than 128 KiB.");
    }
    let mut data = Vec::new();
    file.take((MAX_CONF_SIZE + 1) as u64)
        .read_to_end(&mut data)
        .await
        .map_err(|_| anyhow::anyhow!("Could not read the selected WireGuard file."))?;
    if data.len() > MAX_CONF_SIZE {
        bail!("The selected WireGuard file exceeds 128 KiB.");
    }
    String::from_utf8(data).map_err(|_| anyhow::anyhow!("The WireGuard configuration must be UTF-8 text."))
}
