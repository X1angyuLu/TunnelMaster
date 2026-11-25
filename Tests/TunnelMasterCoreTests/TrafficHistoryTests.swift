import Foundation
import Testing
import TunnelMasterCore

struct TrafficHistoryTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let bucket: TimeInterval = 900
    private let year: TimeInterval = 365 * 24 * 60 * 60

    @Test func mergesQuarterHoursAndPersistsAcrossStoreInstances() async throws {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = TrafficHistoryStore(url: url)
        try await writer.append([
            TrafficHistoryEntry(
                timestamp: base.addingTimeInterval(32), downloaded: 150, uploaded: 20, connectedSeconds: 30.5,
                peakDownloadRate: 15, peakUploadRate: 3, sessionsStarted: 1, peakConnections: 2, samples: 1
            ),
            entry(at: base.addingTimeInterval(bucket), downloaded: 40)
        ])
        try await writer.append([
            TrafficHistoryEntry(
                timestamp: base.addingTimeInterval(899.75), downloaded: 60, uploaded: 5, connectedSeconds: 250.25,
                peakDownloadRate: 20, peakUploadRate: 2, sessionsStarted: 2, peakConnections: 1, samples: 2
            )
        ])

        let reader = TrafficHistoryStore(url: url)
        let result = try await reader.entries(from: base, until: base.addingTimeInterval(2 * bucket))
        #expect(result == [
            TrafficHistoryEntry(
                timestamp: base, downloaded: 210, uploaded: 25, connectedSeconds: 280.75,
                peakDownloadRate: 20, peakUploadRate: 3, sessionsStarted: 3, peakConnections: 2, samples: 3
            ),
            entry(at: base.addingTimeInterval(bucket), downloaded: 40)
        ])
        let nextBucket = base.addingTimeInterval(bucket)
        let exclusive = try await reader.entries(from: base, until: nextBucket)
        #expect(exclusive == Array(result.prefix(1)))
        let fractional = try await reader.entries(from: base.addingTimeInterval(0.125), until: nextBucket.addingTimeInterval(0.125))
        #expect(fractional == Array(result.suffix(1)))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func retainsOneYearOfObservedDataAcrossBackfill() async throws {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = TrafficHistoryStore(url: url)
        let boundary = base.addingTimeInterval(-year)
        let old = boundary.addingTimeInterval(-bucket)
        try await store.append([entry(at: old), entry(at: boundary)])

        let initial = try await store.entries(from: old, until: base)
        #expect(initial.map(\.timestamp) == [old, boundary])
        try await store.append([entry(at: base)])
        try await store.append([entry(at: old, downloaded: 100)])
        let retained = try await store.entries(from: old, until: base.addingTimeInterval(bucket))
        #expect(retained.map(\.timestamp) == [boundary, base])
    }

    @Test func rollsBackInvalidAndOverflowingBatches() async throws {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = TrafficHistoryStore(url: url)
        let existing = entry(at: base, downloaded: .max)
        try await store.append([existing])
        let next = entry(at: base.addingTimeInterval(bucket))

        await #expect(throws: (any Error).self) {
            try await store.append([next, entry(at: base, downloaded: -1)])
        }
        await #expect(throws: (any Error).self) {
            try await store.append([next, entry(at: base, downloaded: 1)])
        }
        let survivors = try await store.entries(from: base, until: base.addingTimeInterval(2 * bucket))
        #expect(survivors == [existing])
    }

    @Test func leavesAnUnreadableLedgerIntact() async throws {
        let url = fixtureURL()
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("The file at this path is not a SQLite database.".utf8)
        try original.write(to: url)

        let store = TrafficHistoryStore(url: url)
        await #expect(throws: (any Error).self) {
            try await store.append([entry(at: base)])
        }
        #expect(try Data(contentsOf: url) == original)
    }

    private func entry(at timestamp: Date, downloaded: Int64 = 0) -> TrafficHistoryEntry {
        TrafficHistoryEntry(
            timestamp: timestamp, downloaded: downloaded, uploaded: 0, connectedSeconds: 0,
            peakDownloadRate: 0, peakUploadRate: 0
        )
    }

    private func fixtureURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TunnelMasterTrafficTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Traffic.sqlite")
    }
}
