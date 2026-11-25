use std::{
    fs::{self, File, OpenOptions},
    io::{ErrorKind, Read as _, Write as _},
    path::{Path, PathBuf},
};

#[cfg(unix)]
use std::os::unix::fs::{DirBuilderExt as _, MetadataExt as _, OpenOptionsExt as _};

use serde::{Deserialize, Serialize};
use specta::Type;

use super::{
    check_droplet,
    client::{parse_droplet_id, parse_token},
    settings_changed,
};
use crate::cmd::{CmdResult, CommandFailure};

const PRIVATE_DIRECTORY: &str = "tunnelmaster-private";
const FILE_NAME: &str = "monitoring.json";
const FILE_LIMIT: u64 = 16 * 1024;
#[cfg(target_os = "macos")]
const ITEM_NOT_FOUND: i32 = -25_300;

#[derive(Clone, Copy, Deserialize, PartialEq, Eq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub enum DigitalOceanCredentialStorage {
    Keychain,
    LocalFile,
}

#[derive(Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct DigitalOceanSettings {
    droplet_id: Option<String>,
    storage: Option<DigitalOceanCredentialStorage>,
    keychain_available: bool,
}

#[derive(Deserialize, Serialize)]
struct SavedSettings {
    droplet_id: String,
    credential: SavedCredential,
}

#[derive(Deserialize, Serialize)]
#[serde(tag = "storage", rename_all = "camelCase")]
enum SavedCredential {
    Keychain { account: String },
    LocalFile { token: String },
}

impl SavedSettings {
    const fn storage(&self) -> DigitalOceanCredentialStorage {
        match self.credential {
            SavedCredential::Keychain { .. } => DigitalOceanCredentialStorage::Keychain,
            SavedCredential::LocalFile { .. } => DigitalOceanCredentialStorage::LocalFile,
        }
    }

    fn summary(&self) -> DigitalOceanSettings {
        DigitalOceanSettings::new(Some(self.droplet_id.clone()), Some(self.storage()))
    }

    fn token(&self) -> CmdResult<String> {
        let token = match &self.credential {
            SavedCredential::Keychain { account } => read_keychain(account)?,
            SavedCredential::LocalFile { token } => token.clone(),
        };
        parse_token(&token)?;
        Ok(token)
    }
}

impl DigitalOceanSettings {
    const fn new(droplet_id: Option<String>, storage: Option<DigitalOceanCredentialStorage>) -> Self {
        Self {
            droplet_id,
            storage,
            keychain_available: cfg!(target_os = "macos"),
        }
    }

    const fn empty() -> Self {
        Self::new(None, None)
    }
}

pub(super) struct CredentialStore {
    directory: PathBuf,
}

impl CredentialStore {
    pub(super) fn open() -> CmdResult<Self> {
        let home = crate::utils::dirs::app_home_dir().map_err(|_| storage_error())?;
        Ok(Self {
            directory: home.join(PRIVATE_DIRECTORY),
        })
    }

    pub(super) fn summary(&self) -> CmdResult<DigitalOceanSettings> {
        Ok(self
            .read()?
            .map_or_else(DigitalOceanSettings::empty, |value| value.summary()))
    }

    pub(super) fn require_empty(&self) -> CmdResult<()> {
        if self.read()?.is_some() {
            return Err(CommandFailure::coded(
                "digital_ocean_migration_configured",
                "DigitalOcean monitoring is already configured in this app.",
            ));
        }
        Ok(())
    }

    pub(super) fn credentials(&self, expected: Option<u64>) -> CmdResult<(u64, String)> {
        let (id, saved) = self.selected(expected)?;
        Ok((id, saved.token()?))
    }

    pub(super) fn change_storage(
        &self,
        storage: DigitalOceanCredentialStorage,
        expected: Option<u64>,
    ) -> CmdResult<DigitalOceanSettings> {
        let (id, saved) = self.selected(expected)?;
        if saved.storage() == storage {
            return Ok(saved.summary());
        }
        self.save(id, saved.token()?, storage)
    }

    fn selected(&self, expected: Option<u64>) -> CmdResult<(u64, SavedSettings)> {
        let saved = self.read()?.ok_or_else(|| {
            if expected.is_some() {
                return settings_changed();
            }
            CommandFailure::coded(
                "digital_ocean_not_configured",
                "Save DigitalOcean credentials and select a Droplet first.",
            )
        })?;
        let id = parse_droplet_id(&saved.droplet_id)?;
        check_droplet(id, expected)?;
        Ok((id, saved))
    }

    pub(super) fn save(
        &self,
        id: u64,
        token: String,
        storage: DigitalOceanCredentialStorage,
    ) -> CmdResult<DigitalOceanSettings> {
        let previous = self.read()?;
        let credential = match storage {
            DigitalOceanCredentialStorage::Keychain => {
                let account = nanoid::nanoid!();
                write_keychain(&account, &token)?;
                SavedCredential::Keychain { account }
            }
            DigitalOceanCredentialStorage::LocalFile => SavedCredential::LocalFile { token },
        };
        let updated = SavedSettings {
            droplet_id: id.to_string(),
            credential,
        };
        if let Err(error) = self.write(&updated) {
            // Remove a staged item while the old settings still point to the working credential.
            if let SavedCredential::Keychain { account } = &updated.credential {
                let _ = remove_keychain(account);
            }
            return Err(error);
        }
        // Settings are committed. An OS denial during cleanup cannot invalidate the new credential.
        if let Some(SavedSettings {
            credential: SavedCredential::Keychain { account },
            ..
        }) = previous
        {
            let _ = remove_keychain(&account);
        }
        Ok(updated.summary())
    }

    pub(super) fn select(&self, id: u64) -> CmdResult<DigitalOceanSettings> {
        let mut saved = self.read()?.ok_or_else(|| {
            CommandFailure::coded(
                "digital_ocean_not_configured",
                "Save DigitalOcean credentials and select a Droplet first.",
            )
        })?;
        saved.droplet_id = id.to_string();
        self.write(&saved)?;
        Ok(saved.summary())
    }

    pub(super) fn clear(&self) -> CmdResult<DigitalOceanSettings> {
        let Some(saved) = self.read()? else {
            return Ok(DigitalOceanSettings::empty());
        };
        if let SavedCredential::Keychain { account } = saved.credential {
            remove_keychain(&account)?;
        }
        fs::remove_file(self.directory.join(FILE_NAME)).map_err(|_| storage_error())?;
        Ok(DigitalOceanSettings::empty())
    }

    fn read(&self) -> CmdResult<Option<SavedSettings>> {
        if !self.check_directory()? {
            return Ok(None);
        }
        let Some(bytes) = read_private_file(&self.directory.join(FILE_NAME))? else {
            return Ok(None);
        };
        serde_json::from_slice(&bytes).map(Some).map_err(|_| storage_error())
    }

    fn write(&self, saved: &SavedSettings) -> CmdResult<()> {
        if !self.check_directory()? {
            let mut builder = fs::DirBuilder::new();
            #[cfg(unix)]
            builder.mode(0o700);
            builder.create(&self.directory).map_err(|_| storage_error())?;
        }
        if !self.check_directory()? {
            return Err(storage_error());
        }
        let bytes = serde_json::to_vec(saved).map_err(|_| storage_error())?;
        if bytes.len() as u64 > FILE_LIMIT {
            return Err(storage_error());
        }
        let pending = self
            .directory
            .join(format!(".monitoring-{}.pending", nanoid::nanoid!()));
        let mut options = OpenOptions::new();
        options.create_new(true).write(true);
        #[cfg(unix)]
        options.mode(0o600);
        let file = options.open(&pending).map_err(|_| storage_error())?;
        if let Err(error) = self.commit(file, &pending, &bytes) {
            let _ = fs::remove_file(pending);
            return Err(error);
        }
        Ok(())
    }

    fn commit(&self, mut file: File, pending: &Path, bytes: &[u8]) -> CmdResult<()> {
        file.write_all(bytes).map_err(|_| storage_error())?;
        file.sync_all().map_err(|_| storage_error())?;
        drop(file);
        fs::rename(pending, self.directory.join(FILE_NAME)).map_err(|_| storage_error())
    }

    fn check_directory(&self) -> CmdResult<bool> {
        match self.directory.symlink_metadata() {
            Ok(metadata) if metadata.is_dir() && private_owned(&metadata) => Ok(true),
            Err(error) if error.kind() == ErrorKind::NotFound => Ok(false),
            _ => Err(storage_error()),
        }
    }
}

pub(super) fn read_private_file(path: &Path) -> CmdResult<Option<Vec<u8>>> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    #[cfg(not(unix))]
    match path.symlink_metadata() {
        Ok(metadata) => check_file(&metadata)?,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(storage_error()),
    }
    let file = match options.open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(storage_error()),
    };
    check_file(&file.metadata().map_err(|_| storage_error())?)?;
    let mut bytes = Vec::new();
    file.take(FILE_LIMIT + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| storage_error())?;
    if bytes.len() as u64 > FILE_LIMIT {
        return Err(storage_error());
    }
    Ok(Some(bytes))
}

fn check_file(metadata: &fs::Metadata) -> CmdResult<()> {
    if !metadata.is_file() || !private_owned(metadata) || metadata.len() > FILE_LIMIT {
        return Err(storage_error());
    }
    Ok(())
}

#[cfg(unix)]
pub(super) fn private_owned(metadata: &fs::Metadata) -> bool {
    // SAFETY: geteuid has no pointer arguments and reads the process's effective UID.
    let uid = unsafe { libc::geteuid() };
    metadata.uid() == uid && metadata.mode() & 0o077 == 0
}

#[cfg(not(unix))]
const fn private_owned(_: &fs::Metadata) -> bool {
    // Windows data resides in the current user's profile with its inherited ACL.
    true
}

fn storage_error() -> CommandFailure {
    CommandFailure::coded(
        "digital_ocean_storage",
        "Could not access the private DigitalOcean settings file.",
    )
}

fn keychain_error() -> CommandFailure {
    CommandFailure::coded(
        "digital_ocean_keychain",
        "Could not access the DigitalOcean credential in macOS Keychain.",
    )
}

#[cfg(target_os = "macos")]
fn keychain_service() -> String {
    format!("{}.digitalocean.monitoring", crate::utils::dirs::APP_ID)
}

#[cfg(target_os = "macos")]
fn read_keychain(account: &str) -> CmdResult<String> {
    use security_framework::passwords::{PasswordOptions, generic_password};
    let bytes = generic_password(PasswordOptions::new_generic_password(&keychain_service(), account))
        .map_err(|_| keychain_error())?;
    String::from_utf8(bytes).map_err(|_| keychain_error())
}

#[cfg(target_os = "macos")]
fn write_keychain(account: &str, token: &str) -> CmdResult<()> {
    security_framework::passwords::set_generic_password(&keychain_service(), account, token.as_bytes())
        .map_err(|_| keychain_error())
}

#[cfg(target_os = "macos")]
fn remove_keychain(account: &str) -> CmdResult<()> {
    match security_framework::passwords::delete_generic_password(&keychain_service(), account) {
        Ok(()) => Ok(()),
        Err(error) if error.code() == ITEM_NOT_FOUND => Ok(()),
        Err(_) => Err(keychain_error()),
    }
}

#[cfg(not(target_os = "macos"))]
fn read_keychain(_: &str) -> CmdResult<String> {
    Err(keychain_error())
}

#[cfg(not(target_os = "macos"))]
fn write_keychain(_: &str, _: &str) -> CmdResult<()> {
    Err(keychain_error())
}

#[cfg(not(target_os = "macos"))]
fn remove_keychain(_: &str) -> CmdResult<()> {
    Err(keychain_error())
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixture(PathBuf);

    impl Fixture {
        fn new() -> CmdResult<Self> {
            let directory = std::env::temp_dir().join(format!("tunnelmaster-storage-test-{}", nanoid::nanoid!()));
            fs::create_dir(&directory).map_err(|_| storage_error())?;
            Ok(Self(directory))
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn local_token_survives_droplet_changes_and_can_be_removed() -> CmdResult<()> {
        let fixture = Fixture::new()?;
        let store = CredentialStore {
            directory: fixture.0.join(PRIVATE_DIRECTORY),
        };
        let token = "synthetic-monitoring-token";
        assert!(store.summary()?.droplet_id.is_none());
        store.require_empty()?;
        let saved = store.save(21, token.to_owned(), DigitalOceanCredentialStorage::LocalFile)?;
        assert_eq!(saved.droplet_id.as_deref(), Some("21"));
        assert!(store.require_empty().is_err());
        let encoded = serde_json::to_string(&saved).map_err(|_| storage_error())?;
        assert!(!encoded.contains(token));
        assert!(encoded.contains("localFile"));
        assert_eq!(store.select(42)?.droplet_id.as_deref(), Some("42"));
        assert_eq!(store.credentials(None)?, (42, token.to_owned()));
        #[cfg(unix)]
        {
            let metadata = store.directory.metadata().map_err(|_| storage_error())?;
            assert_eq!(metadata.mode() & 0o077, 0);
            let metadata = store
                .directory
                .join(FILE_NAME)
                .metadata()
                .map_err(|_| storage_error())?;
            assert_eq!(metadata.mode() & 0o077, 0);
        }
        assert!(store.clear()?.droplet_id.is_none());
        assert!(!store.directory.join(FILE_NAME).exists());
        assert!(store.credentials(None).is_err());
        Ok(())
    }

    #[test]
    fn stale_selection_is_rejected_after_droplet_change_or_removal() -> CmdResult<()> {
        let fixture = Fixture::new()?;
        let store = CredentialStore {
            directory: fixture.0.join(PRIVATE_DIRECTORY),
        };
        let mode = DigitalOceanCredentialStorage::LocalFile;
        store.save(42, "synthetic".into(), mode)?;
        assert!(store.change_storage(mode, Some(21)).is_err());
        assert_eq!(store.change_storage(mode, Some(42))?.droplet_id.as_deref(), Some("42"));
        assert_eq!(store.credentials(Some(42))?, (42, "synthetic".into()));
        assert_eq!(
            store.credentials(Some(21)).err().and_then(|error| error.code),
            settings_changed().code
        );
        store.clear()?;
        assert_eq!(
            store.credentials(Some(42)).err().and_then(|error| error.code),
            settings_changed().code
        );
        assert_eq!(
            store.credentials(None).err().and_then(|error| error.code).as_deref(),
            Some("digital_ocean_not_configured"),
        );
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn private_reader_rejects_symlinks() -> CmdResult<()> {
        let fixture = Fixture::new()?;
        let store = CredentialStore {
            directory: fixture.0.join(PRIVATE_DIRECTORY),
        };
        store.save(21, "synthetic".into(), DigitalOceanCredentialStorage::LocalFile)?;
        let saved = store.directory.join(FILE_NAME);
        let target = fixture.0.join("unrelated");
        fs::rename(&saved, &target).map_err(|_| storage_error())?;
        std::os::unix::fs::symlink(&target, &saved).map_err(|_| storage_error())?;
        assert!(store.credentials(None).is_err());
        assert!(store.clear().is_err());
        assert!(target.exists());
        Ok(())
    }
}
