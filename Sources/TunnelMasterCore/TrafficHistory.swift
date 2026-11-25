import Darwin
import Foundation
import SQLite3

public struct TrafficHistoryEntry: Sendable, Equatable {
    public let timestamp: Date
    public let downloaded: Int64
    public let uploaded: Int64
    public let connectedSeconds: Double
    public let peakDownloadRate: Double
    public let peakUploadRate: Double
    public let sessionsStarted: Int
    public let peakConnections: Int
    public let samples: Int

    public init(
        timestamp: Date, downloaded: Int64, uploaded: Int64, connectedSeconds: Double,
        peakDownloadRate: Double, peakUploadRate: Double, sessionsStarted: Int = 0, peakConnections: Int = 0,
        samples: Int = 0
    ) {
        self.timestamp = timestamp
        self.downloaded = downloaded
        self.uploaded = uploaded
        self.connectedSeconds = connectedSeconds
        self.peakDownloadRate = peakDownloadRate
        self.peakUploadRate = peakUploadRate
        self.sessionsStarted = sessionsStarted
        self.peakConnections = peakConnections
        self.samples = samples
    }
}

/// Stores aggregate session metrics in 15-minute UTC buckets. The app supplies incremental samples.
public actor TrafficHistoryStore {
    public static let bucketSeconds: TimeInterval = 15 * 60
    private static let retentionSeconds: Int64 = 365 * 24 * 60 * 60

    private let url: URL
    private var database: HistoryDatabase?

    public init(url: URL) {
        self.url = url
    }

    public func append(_ entries: [TrafficHistoryEntry]) throws {
        guard !entries.isEmpty else { return }
        let database = try connection()
        try database.execute("BEGIN IMMEDIATE")
        do {
            try database.withStatement("""
                INSERT INTO traffic_15m
                    (timestamp, downloaded, uploaded, connected_seconds, peak_download_rate, peak_upload_rate,
                     sessions_started, peak_connections, samples)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(timestamp) DO UPDATE SET
                    downloaded = downloaded + excluded.downloaded,
                    uploaded = uploaded + excluded.uploaded,
                    connected_seconds = connected_seconds + excluded.connected_seconds,
                    peak_download_rate = MAX(peak_download_rate, excluded.peak_download_rate),
                    peak_upload_rate = MAX(peak_upload_rate, excluded.peak_upload_rate),
                    sessions_started = sessions_started + excluded.sessions_started,
                    peak_connections = MAX(peak_connections, excluded.peak_connections),
                    samples = samples + excluded.samples
                """) { statement in
                for entry in entries {
                    let interval = entry.timestamp.timeIntervalSince1970
                    let bucket = floor(interval / Self.bucketSeconds) * Self.bucketSeconds
                    guard let timestamp = Int64(exactly: bucket),
                          entry.downloaded >= 0, entry.uploaded >= 0,
                          entry.connectedSeconds.isFinite, entry.connectedSeconds >= 0,
                          entry.peakDownloadRate.isFinite, entry.peakDownloadRate >= 0,
                          entry.peakUploadRate.isFinite, entry.peakUploadRate >= 0,
                          entry.sessionsStarted >= 0, entry.peakConnections >= 0, entry.samples >= 0 else {
                        throw TrafficHistoryError.invalidEntry
                    }
                    try database.check(sqlite3_bind_int64(statement, 1, timestamp))
                    try database.check(sqlite3_bind_int64(statement, 2, entry.downloaded))
                    try database.check(sqlite3_bind_int64(statement, 3, entry.uploaded))
                    try database.check(sqlite3_bind_double(statement, 4, entry.connectedSeconds))
                    try database.check(sqlite3_bind_double(statement, 5, entry.peakDownloadRate))
                    try database.check(sqlite3_bind_double(statement, 6, entry.peakUploadRate))
                    try database.check(sqlite3_bind_int64(statement, 7, Int64(entry.sessionsStarted)))
                    try database.check(sqlite3_bind_int64(statement, 8, Int64(entry.peakConnections)))
                    try database.check(sqlite3_bind_int64(statement, 9, Int64(entry.samples)))
                    try database.check(sqlite3_step(statement), expected: SQLITE_DONE)
                    try database.check(sqlite3_reset(statement))
                }
            }
            // Anchor retention to the newest recorded bucket so importing or backfilling older data is consistent.
            try database.withStatement("""
                DELETE FROM traffic_15m
                WHERE timestamp < (SELECT MAX(timestamp) - ? FROM traffic_15m)
                """) { statement in
                try database.check(sqlite3_bind_int64(statement, 1, Self.retentionSeconds))
                try database.check(sqlite3_step(statement), expected: SQLITE_DONE)
            }
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    /// Returns the buckets whose start timestamps fall within the half-open range.
    public func entries(from: Date, until: Date) throws -> [TrafficHistoryEntry] {
        guard let lowerBound = Int64(exactly: ceil(from.timeIntervalSince1970)),
              let upperBound = Int64(exactly: ceil(until.timeIntervalSince1970)) else {
            throw TrafficHistoryError.invalidEntry
        }
        guard lowerBound < upperBound else { return [] }
        let database = try connection()
        return try database.withStatement("""
            SELECT timestamp, downloaded, uploaded, connected_seconds, peak_download_rate, peak_upload_rate,
                   sessions_started, peak_connections, samples
            FROM traffic_15m
            WHERE timestamp >= ? AND timestamp < ?
            ORDER BY timestamp
            """) { statement in
            try database.check(sqlite3_bind_int64(statement, 1, lowerBound))
            try database.check(sqlite3_bind_int64(statement, 2, upperBound))
            var result: [TrafficHistoryEntry] = []
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                result.append(TrafficHistoryEntry(
                    timestamp: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
                    downloaded: sqlite3_column_int64(statement, 1),
                    uploaded: sqlite3_column_int64(statement, 2),
                    connectedSeconds: sqlite3_column_double(statement, 3),
                    peakDownloadRate: sqlite3_column_double(statement, 4),
                    peakUploadRate: sqlite3_column_double(statement, 5),
                    sessionsStarted: Int(sqlite3_column_int64(statement, 6)),
                    peakConnections: Int(sqlite3_column_int64(statement, 7)),
                    samples: Int(sqlite3_column_int64(statement, 8))
                ))
                status = sqlite3_step(statement)
            }
            try database.check(status, expected: SQLITE_DONE)
            return result
        }
    }

    private func connection() throws -> HistoryDatabase {
        if let database { return database }
        let opened = try HistoryDatabase(url: url)
        database = opened
        return opened
    }
}

private enum TrafficHistoryError: LocalizedError {
    case invalidEntry
    case inaccessibleFile
    case database(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidEntry: return "无效的流量统计数据。"
        case .inaccessibleFile: return "无法打开私有流量统计文件。"
        case .database(let code): return "流量统计数据库操作失败（SQLite \(code)）。"
        }
    }
}

private final class HistoryDatabase {
    private let handle: OpaquePointer

    init(url: URL) throws {
        let path = try Self.prepareFile(at: url)
        var database: OpaquePointer?
        let result = sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil)
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw TrafficHistoryError.database(result)
        }
        let timeout = sqlite3_busy_timeout(database, 2_000)
        let schema = timeout == SQLITE_OK ? sqlite3_exec(database, """
            CREATE TABLE IF NOT EXISTS traffic_15m (
                timestamp INTEGER PRIMARY KEY,
                downloaded INTEGER NOT NULL CHECK(typeof(downloaded) = 'integer' AND downloaded >= 0),
                uploaded INTEGER NOT NULL CHECK(typeof(uploaded) = 'integer' AND uploaded >= 0),
                connected_seconds REAL NOT NULL CHECK(connected_seconds BETWEEN 0 AND 1.7976931348623157e308),
                peak_download_rate REAL NOT NULL CHECK(peak_download_rate >= 0),
                peak_upload_rate REAL NOT NULL CHECK(peak_upload_rate >= 0),
                sessions_started INTEGER NOT NULL CHECK(typeof(sessions_started) = 'integer' AND sessions_started >= 0),
                peak_connections INTEGER NOT NULL CHECK(peak_connections >= 0),
                samples INTEGER NOT NULL CHECK(typeof(samples) = 'integer' AND samples >= 0)
            );
            """, nil, nil, nil) : timeout
        guard schema == SQLITE_OK else {
            sqlite3_close(database)
            throw TrafficHistoryError.database(schema)
        }
        handle = database
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }

    func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil))
        guard let statement else { throw TrafficHistoryError.database(SQLITE_ERROR) }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    func check(_ code: Int32, expected: Int32 = SQLITE_OK) throws {
        guard code == expected else { throw TrafficHistoryError.database(code) }
    }

    private static func prepareFile(at url: URL) throws -> String {
        guard url.isFileURL else { throw TrafficHistoryError.inaccessibleFile }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        // Keep genuine paths such as /private/var. Foundation can normalize them back to /var,
        // whose symlink SQLite rejects with SQLITE_OPEN_NOFOLLOW.
        guard let physicalPath = realpath(directory.path, nil) else { throw TrafficHistoryError.inaccessibleFile }
        defer { free(physicalPath) }
        let path = (String(cString: physicalPath) as NSString).appendingPathComponent(url.lastPathComponent)
        let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw TrafficHistoryError.inaccessibleFile }
        defer { Darwin.close(descriptor) }

        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(),
              fchmod(descriptor, 0o600) == 0 else {
            throw TrafficHistoryError.inaccessibleFile
        }
        return path
    }
}
