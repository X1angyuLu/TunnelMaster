use super::{
    MAX_CONF_SIZE,
    rules::{NATIVE_DIRECT_DOMAINS, TunnelMasterRules, UnmatchedTraffic},
};
use crate::cmd::{CmdResult, CommandFailure, coded_error};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use objc2::{rc::autoreleasepool, runtime::AnyObject};
use objc2_foundation::{NSDictionary, NSNumber, NSString, NSUserDefaults};
use std::{
    fs::{File, Metadata, OpenOptions},
    io::{ErrorKind, Read as _},
    os::{
        fd::{AsRawFd as _, FromRawFd as _},
        unix::fs::{MetadataExt as _, OpenOptionsExt as _},
    },
    path::Path,
};

const NATIVE_APP: &str = "TunnelMaster";
const PREVIOUS_APP: &str = "TunnelMenu";
const NATIVE_DOMAIN: &str = "com.x1angyulu.TunnelMaster";
const PREVIOUS_DOMAIN: &str = "com.x1angyulu.TunnelMenu";
const NAME_PREFIX: &str = "# TunnelMaster profile name: ";

pub(super) struct NativeProfile {
    pub(super) source: String,
    pub(super) name: String,
    pub(super) rules: TunnelMasterRules,
}

pub(super) fn read_native_profile() -> CmdResult<NativeProfile> {
    let support = dirs::data_dir().ok_or_else(unreadable)?;
    let source = legacy_source(&support)?;
    let name = profile_name(&source);
    let rules = autoreleasepool(|_| {
        let defaults = NSUserDefaults::standardUserDefaults();
        let current = defaults.persistentDomainForName(&NSString::from_str(NATIVE_DOMAIN));
        let inherited = defaults.persistentDomainForName(&NSString::from_str(PREVIOUS_DOMAIN));
        legacy_rules(current.as_deref(), inherited.as_deref())
    })?;
    Ok(NativeProfile { source, name, rules })
}

fn legacy_source(support: &Path) -> CmdResult<String> {
    fn open_dir(path: &Path) -> std::io::Result<File> {
        OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
            .open(path)
    }

    let directory = match open_dir(&support.join(NATIVE_APP)) {
        Err(error) if error.kind() == ErrorKind::NotFound => open_dir(&support.join(PREVIOUS_APP)),
        result => result,
    }
    .map_err(|error| {
        if error.kind() == ErrorKind::NotFound {
            missing()
        } else {
            unreadable()
        }
    })?;
    if !private_owned(&directory.metadata().map_err(|_| unreadable())?) {
        return Err(unreadable());
    }

    // The directory descriptor keeps the source anchored if the directory is renamed during import.
    // SAFETY: the descriptor is live, the path is a static C string, and these flags never create a file.
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            c"profile.conf".as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(match std::io::Error::last_os_error().kind() {
            ErrorKind::NotFound => missing(),
            _ => unreadable(),
        });
    }
    // SAFETY: openat returned this newly owned descriptor, which has not been transferred elsewhere.
    let file = unsafe { File::from_raw_fd(fd) };
    let metadata = file.metadata().map_err(|_| unreadable())?;
    if !metadata.is_file() || !private_owned(&metadata) || metadata.len() > MAX_CONF_SIZE as u64 {
        return Err(unreadable());
    }
    let mut bytes = Vec::new();
    file.take(MAX_CONF_SIZE as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| unreadable())?;
    if bytes.len() > MAX_CONF_SIZE {
        return Err(unreadable());
    }
    String::from_utf8(bytes).map_err(|_| unreadable())
}

fn private_owned(metadata: &Metadata) -> bool {
    // SAFETY: geteuid takes no arguments and queries the process's effective UID.
    metadata.uid() == unsafe { libc::geteuid() } && metadata.mode() & 0o077 == 0
}

fn profile_name(source: &str) -> String {
    source
        .trim_start_matches('\u{feff}')
        .lines()
        .next()
        .and_then(|line| line.strip_prefix(NAME_PREFIX))
        .and_then(|encoded| STANDARD.decode(encoded).ok())
        .and_then(|bytes| String::from_utf8(bytes).ok())
        .filter(|name| !name.trim().is_empty())
        .unwrap_or_else(|| "TunnelMaster WireGuard".to_owned())
}

type PreferencesDomain = NSDictionary<NSString, AnyObject>;

fn legacy_rules(
    current: Option<&PreferencesDomain>,
    inherited: Option<&PreferencesDomain>,
) -> CmdResult<TunnelMasterRules> {
    let read = |key: &str, allow_inherited: bool| {
        let key = NSString::from_str(key);
        current.and_then(|domain| domain.objectForKey(&key)).or_else(|| {
            inherited
                .filter(|_| allow_inherited)
                .and_then(|domain| domain.objectForKey(&key))
        })
    };
    let string = |key, allow_inherited| {
        read(key, allow_inherited)
            .map(|object| {
                object
                    .downcast::<NSString>()
                    .map(|value| value.to_string())
                    .map_err(|_| invalid_preferences())
            })
            .transpose()
    };
    let china_ip_direct = read("useChinaIPRules", true)
        .map(|value| {
            value
                .downcast::<NSNumber>()
                .map(|value| value.boolValue())
                .map_err(|_| invalid_preferences())
        })
        .transpose()?
        .unwrap_or_default();
    // Rule fallback was stored only by the newer native TunnelMaster app.
    let unmatched = match string("ruleFallback", false)?.as_deref() {
        Some("direct") => UnmatchedTraffic::Direct,
        _ => UnmatchedTraffic::Wireguard,
    };
    let direct_domains = string("directDomains", true)?.map_or_else(
        || {
            NATIVE_DIRECT_DOMAINS
                .iter()
                .map(|domain| (*domain).to_owned())
                .collect()
        },
        |value| split_domains(&value),
    );
    let proxy_domains = string("proxyDomains", true)?
        .map(|value| split_domains(&value))
        .unwrap_or_default();
    Ok(TunnelMasterRules {
        direct_domains,
        proxy_domains,
        china_ip_direct,
        unmatched,
    })
}

fn split_domains(input: &str) -> Vec<String> {
    input
        .split(|ch: char| ch.is_whitespace() || matches!(ch, ',' | '，'))
        .filter(|domain| !domain.is_empty())
        .map(str::to_owned)
        .collect()
}

fn missing() -> CommandFailure {
    coded_error(
        "NATIVE_WIREGUARD_IMPORT_MISSING",
        "No WireGuard profile was found in the original TunnelMaster app.",
    )
}

fn unreadable() -> CommandFailure {
    coded_error(
        "NATIVE_WIREGUARD_IMPORT_UNREADABLE",
        "Could not safely read the original TunnelMaster WireGuard profile.",
    )
}

fn invalid_preferences() -> CommandFailure {
    coded_error(
        "NATIVE_WIREGUARD_IMPORT_FAILED",
        "The original TunnelMaster routing preferences are invalid.",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::{DirBuilderExt as _, PermissionsExt as _, symlink},
        path::PathBuf,
    };

    struct Fixture(PathBuf);

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn reads_only_the_original_app_profile_and_rejects_symlinks() -> CmdResult<()> {
        let support = std::env::temp_dir().join(format!("tm-profile-migration-{}", nanoid::nanoid!()));
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&support)
            .map_err(|_| unreadable())?;
        let fixture = Fixture(support);
        let directory = fixture.0.join(PREVIOUS_APP);
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&directory)
            .map_err(|_| unreadable())?;
        let path = directory.join("profile.conf");
        let config = format!("{NAME_PREFIX}{}\n[Interface]\n", STANDARD.encode("测试名称"));
        fs::write(&path, &config).map_err(|_| unreadable())?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).map_err(|_| unreadable())?;
        assert_eq!(profile_name(&legacy_source(&fixture.0)?), "测试名称");
        let current = fixture.0.join(NATIVE_APP);
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&current)
            .map_err(|_| unreadable())?;
        symlink(&path, current.join("profile.conf")).map_err(|_| unreadable())?;
        assert!(legacy_source(&fixture.0).is_err());
        assert_eq!(fs::read_to_string(&path).map_err(|_| unreadable())?, config);
        Ok(())
    }

    #[test]
    fn imports_native_routing_values_without_taking_the_active_mode() -> CmdResult<()> {
        autoreleasepool(|_| {
            let empty = NSString::from_str("");
            let proxy = NSString::from_str("unused-old.example\na.b.example，other.example");
            let flag = NSNumber::new_bool(true);
            let fallback = NSString::from_str("direct");
            let mode = NSString::from_str("global");
            let inherited = PreferencesDomain::from_slices(
                &[
                    &*NSString::from_str("proxyDomains"),
                    &*NSString::from_str("ruleFallback"),
                ],
                &[&*proxy, &*fallback],
            );
            let current = PreferencesDomain::from_slices(
                &[
                    &*NSString::from_str("directDomains"),
                    &*NSString::from_str("routingMode"),
                    &*NSString::from_str("useChinaIPRules"),
                ],
                &[&*empty, &*mode, &*flag],
            );
            let rules = legacy_rules(Some(&current), Some(&inherited))?;
            assert!(rules.direct_domains.is_empty());
            assert_eq!(
                rules.proxy_domains,
                ["unused-old.example", "a.b.example", "other.example"]
            );
            assert!(rules.china_ip_direct);
            assert!(rules.unmatched == UnmatchedTraffic::Wireguard);

            let defaults = legacy_rules(None, None)?;
            assert_eq!(defaults.direct_domains, NATIVE_DIRECT_DOMAINS);
            assert!(defaults.proxy_domains.is_empty());
            assert!(!defaults.china_ip_direct);
            let current = PreferencesDomain::from_slices(&[&*NSString::from_str("ruleFallback")], &[&*fallback]);
            let current = legacy_rules(Some(&current), None)?;
            assert!(current.unmatched == UnmatchedTraffic::Direct);
            Ok(())
        })
    }
}
