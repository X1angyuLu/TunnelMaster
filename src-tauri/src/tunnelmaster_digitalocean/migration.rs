use crate::cmd::{CmdResult, CommandFailure};

#[cfg(target_os = "macos")]
use {
    super::{
        client::{parse_droplet_id, parse_token},
        storage::{private_owned, read_private_file},
    },
    objc2::rc::autoreleasepool,
    objc2_foundation::{NSDictionary, NSString, NSUserDefaults},
    serde::Deserialize,
    std::path::Path,
};

#[cfg(target_os = "macos")]
const NATIVE_DOMAIN: &str = "com.x1angyulu.TunnelMaster";
#[cfg(target_os = "macos")]
const CREDENTIAL_FILE: &str = "digitalocean-credentials.json";

#[cfg(target_os = "macos")]
pub(super) fn native_credentials() -> CmdResult<(u64, String)> {
    let configuration = autoreleasepool(|_| {
        let domain = NSUserDefaults::standardUserDefaults()
            .persistentDomainForName(&NSString::from_str(NATIVE_DOMAIN))
            .ok_or_else(missing)?;
        let Some(configuration) = domain.objectForKey(&NSString::from_str("digitalOceanConfiguration")) else {
            if domain
                .objectForKey(&NSString::from_str("digitalOceanDropletID"))
                .is_some()
            {
                return Err(keychain_only());
            }
            return Err(missing());
        };
        let configuration = configuration.downcast::<NSDictionary>().map_err(|_| invalid())?;
        let string = |key: &str| {
            configuration
                .objectForKey(&NSString::from_str(key))?
                .downcast::<NSString>()
                .ok()
                .map(|value| value.to_string())
        };
        match string("storage").as_deref() {
            Some("localFile") => {}
            Some("keychain") | None => return Err(keychain_only()),
            _ => return Err(invalid()),
        }
        let original = string("dropletID").ok_or_else(invalid)?;
        let selected = string("selectedDropletID").unwrap_or_else(|| original.clone());
        Ok((original, selected))
    })?;
    let directory = dirs::data_dir().ok_or_else(invalid)?.join("TunnelMaster");
    read_native_file(&directory, &configuration.0, &configuration.1)
}

#[cfg(not(target_os = "macos"))]
pub(super) fn native_credentials() -> CmdResult<(u64, String)> {
    Err(CommandFailure::coded(
        "digital_ocean_migration_unavailable",
        "Native TunnelMaster DigitalOcean settings can be imported on macOS.",
    ))
}

#[cfg(target_os = "macos")]
fn read_native_file(directory: &Path, original: &str, selected: &str) -> CmdResult<(u64, String)> {
    if !directory
        .symlink_metadata()
        .is_ok_and(|metadata| metadata.is_dir() && private_owned(&metadata))
    {
        return Err(invalid());
    }
    let bytes = read_private_file(&directory.join(CREDENTIAL_FILE))
        .map_err(|_| invalid())?
        .ok_or_else(invalid)?;
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct NativeCredential {
        #[serde(rename = "dropletID")]
        droplet_id: String,
        token: String,
    }
    let stored: NativeCredential = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
    if stored.droplet_id != original {
        return Err(invalid());
    }
    let id = parse_droplet_id(selected).map_err(|_| invalid())?;
    let token = parse_token(&stored.token).map_err(|_| invalid())?;
    Ok((id, token.to_owned()))
}

#[cfg(target_os = "macos")]
fn missing() -> CommandFailure {
    CommandFailure::coded(
        "digital_ocean_migration_missing",
        "No DigitalOcean configuration was found in the native TunnelMaster app. Enter your token to connect.",
    )
}

#[cfg(target_os = "macos")]
fn invalid() -> CommandFailure {
    CommandFailure::coded(
        "digital_ocean_migration_invalid",
        "Could not safely read the native TunnelMaster DigitalOcean settings. Save the token locally in that app or enter it here.",
    )
}

#[cfg(target_os = "macos")]
fn keychain_only() -> CommandFailure {
    CommandFailure::coded(
        "digital_ocean_migration_keychain",
        "The native TunnelMaster app uses macOS Keychain. Choose local file storage and Save to Local File in that app, or enter your token here.",
    )
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::{CREDENTIAL_FILE, read_native_file};
    use crate::cmd::CmdResult;
    use std::{
        fs,
        io::Write as _,
        os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _},
        path::PathBuf,
    };

    struct Fixture(PathBuf);

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn reads_swift_credential_shape_and_preserves_selected_droplet() -> CmdResult<()> {
        let path = std::env::temp_dir().join(format!("tunnelmaster-native-test-{}", nanoid::nanoid!()));
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&path)
            .map_err(|_| super::invalid())?;
        let fixture = Fixture(path);
        let legacy_path = fixture.0.join(CREDENTIAL_FILE);
        let mut file = fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&legacy_path)
            .map_err(|_| super::invalid())?;
        let data = br#"{"dropletID":"21","token":"synthetic"}"#;
        file.write_all(data).map_err(|_| super::invalid())?;
        drop(file);
        assert_eq!(read_native_file(&fixture.0, "21", "42")?, (42, "synthetic".into()));
        assert!(read_native_file(&fixture.0, "99", "42").is_err());
        assert_eq!(fs::read(&legacy_path).map_err(|_| super::invalid())?, data);
        Ok(())
    }
}
