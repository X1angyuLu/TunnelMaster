import Foundation
import Testing
@testable import TunnelMasterCore

struct TrafficHistoryRecorderTests {
    @Test func stopsAtQuarterHourAndRetainsCounterAcrossMissingRead() {
        let boundary = Date(timeIntervalSince1970: 1_800)
        var recorder = TrafficHistoryRecorder()
        _ = recorder.record(
            at: boundary.addingTimeInterval(-7), connectedSeconds: 3, totals: (100, 25),
            downloadRate: nil, uploadRate: nil, connections: 1
        )
        let missing = recorder.record(
            at: boundary.addingTimeInterval(-2), connectedSeconds: 5, totals: nil,
            downloadRate: nil, uploadRate: nil, connections: 0
        )
        #expect(missing.first?.samples == 0)

        let entries = recorder.record(
            at: boundary.addingTimeInterval(3), connectedSeconds: 5, totals: (240, 50),
            downloadRate: 30, uploadRate: 5, connections: 3
        )
        #expect(entries.count == 2)
        #expect(entries[0].timestamp == boundary)
        #expect(entries[0].connectedSeconds == 3)
        #expect(entries[0].downloaded == 140)
        #expect(entries[0].uploaded == 25)
        #expect(entries[0].peakConnections == 3)
        #expect(entries[0].samples == 1)
        #expect(entries[1].timestamp == boundary.addingTimeInterval(-900))
        #expect(entries[1].connectedSeconds == 2)
        #expect(entries[1].samples == 0)
    }

    @Test func startsAdoptedEngineAtExistingCountersAndHandlesReset() {
        var recorder = TrafficHistoryRecorder(downloaded: 1000, uploaded: 200)
        let at = Date(timeIntervalSince1970: 1_920)
        let continued = recorder.record(
            at: at, connectedSeconds: 2, totals: (1050, 204),
            downloadRate: nil, uploadRate: nil, connections: 0
        )
        #expect(continued.first?.downloaded == 50)
        #expect(continued.first?.uploaded == 4)
        let reset = recorder.record(
            at: at.addingTimeInterval(3), connectedSeconds: 3, totals: (12, 3),
            downloadRate: nil, uploadRate: nil, connections: 0
        )
        #expect(reset.first?.downloaded == 12)
        #expect(reset.first?.uploaded == 3)
    }
}
