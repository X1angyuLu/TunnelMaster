import Foundation

public struct TrafficHistoryRecorder {
    public static let interval: TimeInterval = 15 * 60

    private var lastDownload: Int64
    private var lastUpload: Int64

    public init(downloaded: Int64 = 0, uploaded: Int64 = 0) {
        lastDownload = downloaded
        lastUpload = uploaded
    }

    public static func bucketStart(for timestamp: Date) -> Date {
        Date(timeIntervalSince1970: floor(timestamp.timeIntervalSince1970 / interval) * interval)
    }

    public mutating func record(
        at timestamp: Date,
        connectedSeconds: TimeInterval,
        totals: (downloaded: Int64, uploaded: Int64)?,
        downloadRate: Double?,
        uploadRate: Double?,
        connections: Int
    ) -> [TrafficHistoryEntry] {
        let bucket = Self.bucketStart(for: timestamp)
        let duration = max(0, min(Self.interval, connectedSeconds))
        let start = timestamp.addingTimeInterval(-duration)
        let previousDuration = max(0, bucket.timeIntervalSince(start))
        var downloaded: Int64 = 0
        var uploaded: Int64 = 0
        if let totals {
            // A missing sample doesn't lose the baseline. A counter reset starts a new one.
            downloaded = totals.downloaded >= lastDownload ? totals.downloaded - lastDownload : totals.downloaded
            uploaded = totals.uploaded >= lastUpload ? totals.uploaded - lastUpload : totals.uploaded
            lastDownload = totals.downloaded
            lastUpload = totals.uploaded
        }
        var entries = [TrafficHistoryEntry(
            timestamp: bucket, downloaded: downloaded, uploaded: uploaded,
            connectedSeconds: duration - previousDuration,
            peakDownloadRate: downloadRate ?? 0, peakUploadRate: uploadRate ?? 0,
            peakConnections: connections, samples: totals == nil ? 0 : 1
        )]
        if previousDuration > 0 {
            entries.append(TrafficHistoryEntry(
                timestamp: Self.bucketStart(for: start), downloaded: 0, uploaded: 0,
                connectedSeconds: previousDuration, peakDownloadRate: 0, peakUploadRate: 0
            ))
        }
        return entries
    }
}
