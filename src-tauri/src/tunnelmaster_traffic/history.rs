use super::LocalTrafficBucket;
use anyhow::{Context as _, Result, ensure};
use rusqlite::{Connection, OpenFlags, params};
use std::{fs, path::Path, time::Duration};

pub const STORAGE_BUCKET: i64 = 900;
const RETENTION: i64 = 365 * 24 * 3600;
const SCHEMA: &str = "
    CREATE TABLE IF NOT EXISTS traffic (
        timestamp INTEGER PRIMARY KEY,
        upload INTEGER NOT NULL,
        download INTEGER NOT NULL,
        connected_seconds REAL NOT NULL,
        peak_upload_rate INTEGER NOT NULL,
        peak_download_rate INTEGER NOT NULL,
        sessions_started INTEGER NOT NULL,
        peak_connections INTEGER,
        samples INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY);
";
const UPSERT: &str = "
    INSERT INTO traffic VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(timestamp) DO UPDATE SET
        upload = upload + excluded.upload,
        download = download + excluded.download,
        connected_seconds = connected_seconds + excluded.connected_seconds,
        peak_upload_rate = MAX(peak_upload_rate, excluded.peak_upload_rate),
        peak_download_rate = MAX(peak_download_rate, excluded.peak_download_rate),
        sessions_started = sessions_started + excluded.sessions_started,
        peak_connections = CASE
            WHEN peak_connections IS NULL THEN excluded.peak_connections
            WHEN excluded.peak_connections IS NULL THEN peak_connections
            ELSE MAX(peak_connections, excluded.peak_connections)
        END,
        samples = samples + excluded.samples
";

pub struct StorageSample {
    pub timestamp: i64,
    pub upload: u64,
    pub download: u64,
    pub connected_seconds: f64,
    pub peak_upload_rate: u64,
    pub peak_download_rate: u64,
    pub sessions_started: u32,
    pub peak_connections: Option<u32>,
    pub samples: u32,
}
pub struct History(Connection);

impl History {
    pub fn open(path: &Path, legacy: Option<std::path::PathBuf>) -> Result<Self> {
        let parent = path.parent().context("Invalid traffic history path")?;
        let mut builder = fs::DirBuilder::new();
        builder.recursive(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt as _;
            builder.mode(0o700);
        }
        builder.create(parent)?;
        ensure!(
            !fs::symlink_metadata(parent)?.file_type().is_symlink(),
            "Unsafe traffic history directory"
        );
        let path = parent
            .canonicalize()?
            .join(path.file_name().context("Invalid traffic history file")?);
        ensure!(
            fs::symlink_metadata(&path).is_err() || !path.is_symlink(),
            "Unsafe traffic history path"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::{OpenOptionsExt as _, PermissionsExt as _};
            fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
            let file = fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(false)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
                .open(&path)?;
            ensure!(file.metadata()?.is_file(), "Invalid traffic history file");
            file.set_permissions(fs::Permissions::from_mode(0o600))?;
        }
        let db = Connection::open_with_flags(&path, OpenFlags::default() | OpenFlags::SQLITE_OPEN_NOFOLLOW)?;
        db.busy_timeout(Duration::from_secs(2))?;
        db.execute_batch(SCHEMA)?;
        let mut history = Self(db);
        if let Some(legacy) = legacy
            && let Err(error) = history.import_legacy(&legacy)
        {
            use std::sync::atomic::{AtomicBool, Ordering};
            static REPORTED: AtomicBool = AtomicBool::new(false);
            if !REPORTED.swap(true, Ordering::Relaxed) {
                clash_verge_logging::logging!(
                    warn,
                    clash_verge_logging::Type::File,
                    "Legacy traffic history: {error:#}"
                );
            }
        }
        Ok(history)
    }

    pub fn append(&mut self, samples: &[StorageSample]) -> Result<()> {
        let tx = self.0.transaction()?;
        {
            let mut statement = tx.prepare_cached(UPSERT)?;
            for sample in samples {
                statement.execute(params![
                    sample.timestamp.div_euclid(STORAGE_BUCKET) * STORAGE_BUCKET,
                    i64::try_from(sample.upload)?,
                    i64::try_from(sample.download)?,
                    sample.connected_seconds,
                    i64::try_from(sample.peak_upload_rate)?,
                    i64::try_from(sample.peak_download_rate)?,
                    sample.sessions_started,
                    sample.peak_connections,
                    sample.samples,
                ])?;
            }
        }
        tx.execute(
            "DELETE FROM traffic WHERE timestamp < (SELECT MAX(timestamp) - ? FROM traffic)",
            [RETENTION],
        )?;
        tx.commit()?;
        Ok(())
    }

    pub fn read(&self, from: i64, until: i64, bucket_seconds: i64) -> Result<Vec<LocalTrafficBucket>> {
        let mut statement = self.0.prepare_cached(
            "SELECT (timestamp / ?3) * ?3 AS bucket,
                    SUM(upload), SUM(download), SUM(samples), SUM(connected_seconds),
                    MAX(peak_download_rate), MAX(peak_upload_rate), MAX(peak_connections),
                    SUM(sessions_started)
             FROM traffic WHERE timestamp >= ?1 AND timestamp < ?2
             GROUP BY bucket ORDER BY bucket",
        )?;
        let rows = statement.query_map(params![from, until, bucket_seconds], |row| {
            Ok(LocalTrafficBucket {
                start: row.get(0)?,
                upload: row.get::<_, i64>(1)?.max(0) as u64,
                download: row.get::<_, i64>(2)?.max(0) as u64,
                samples: row.get(3)?,
                connected_seconds: row.get(4)?,
                peak_download_rate: row.get::<_, i64>(5)?.max(0) as u64,
                peak_upload_rate: row.get::<_, i64>(6)?.max(0) as u64,
                peak_connections: row.get(7)?,
                sessions_started: row.get(8)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    fn import_legacy(&mut self, legacy: &Path) -> Result<()> {
        let legacy_key = "native-history-v1";
        if self.0.query_row(
            "SELECT EXISTS(SELECT 1 FROM metadata WHERE key = ?)",
            [legacy_key],
            |row| row.get::<_, bool>(0),
        )? {
            return Ok(());
        }
        ensure!(!legacy.is_symlink(), "Invalid legacy history path");
        let source = Connection::open_with_flags(
            legacy.canonicalize()?,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )?;
        source.busy_timeout(Duration::from_secs(1))?;
        let mut read = source.prepare(
            "SELECT timestamp, uploaded, downloaded, connected_seconds, peak_upload_rate, peak_download_rate,
                    sessions_started, peak_connections, samples
             FROM traffic_15m WHERE timestamp >= ? AND timestamp <= ?",
        )?;
        let now = chrono::Utc::now().timestamp();
        let mut rows = read.query(params![now - RETENTION, now])?;
        let tx = self
            .0
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let added = tx.execute("INSERT OR IGNORE INTO metadata VALUES (?)", [legacy_key])?;
        if added != 0 {
            let mut insert = tx.prepare_cached(UPSERT)?;
            while let Some(row) = rows.next()? {
                insert.execute(params![
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, f64>(3)?,
                    row.get::<_, f64>(4)?.max(0.0).round() as i64,
                    row.get::<_, f64>(5)?.max(0.0).round() as i64,
                    row.get::<_, u32>(6)?,
                    row.get::<_, u32>(7)?,
                    row.get::<_, u32>(8)?,
                ])?;
            }
        }
        tx.commit()?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_import_and_new_samples_persist_once_across_reopen() -> Result<()> {
        let parent = std::env::temp_dir().join(format!("tm-history-{}", nanoid::nanoid!()));
        fs::create_dir(&parent)?;
        let _cleanup = scopeguard::guard(&parent, |path| {
            let _ = fs::remove_dir_all(path);
        });
        let legacy = parent.join("legacy.sqlite3");
        let current = parent.join("history.sqlite3");
        let now = chrono::Utc::now().timestamp();
        let timestamp = (now - 900).div_euclid(900) * 900;
        let old = Connection::open(&legacy)?;
        old.execute_batch(
            "CREATE TABLE traffic_15m (
                timestamp INTEGER PRIMARY KEY, downloaded INTEGER, uploaded INTEGER, connected_seconds REAL,
                peak_download_rate REAL, peak_upload_rate REAL, sessions_started INTEGER, peak_connections INTEGER,
                samples INTEGER
            )",
        )?;
        old.execute(
            "INSERT INTO traffic_15m VALUES (?, 80, 10, 5.0, 23.0, 3.0, 1, 2, 1)",
            [timestamp],
        )?;
        let mut db = History::open(&current, Some(legacy.clone()))?;
        db.append(&[StorageSample {
            timestamp: timestamp + 12,
            download: 15,
            upload: 2,
            connected_seconds: 5.0,
            peak_upload_rate: 1,
            peak_download_rate: 3,
            sessions_started: 0,
            peak_connections: None,
            samples: 1,
        }])?;
        drop(db);
        let db = History::open(&current, Some(legacy))?;
        let data = db.read(timestamp, now, 900)?;
        assert_eq!(data.len(), 1);
        assert_eq!((data[0].download, data[0].upload, data[0].samples), (95, 12, 2));
        assert_eq!((data[0].peak_connections, data[0].sessions_started), (Some(2), 1));
        Ok(())
    }
}
