import Foundation
import TunnelMasterCore

enum MenuTrafficRange: String, CaseIterable, Identifiable {
    case day, week

    var id: Self { self }
    var title: String { usageRange.rawValue }
    var days: Int { usageRange.dayCount }

    func interval(now: Date) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-Double(days) * 86_400), end: now)
    }

    func localInterval(now: Date, calendar: Calendar = .current) -> DateInterval {
        UsagePeriod(range: usageRange, now: now, calendar: calendar).current
    }

    fileprivate var usageRange: UsageRange {
        switch self {
        case .day: .day
        case .week: .week
        }
    }
}

struct MenuTrafficBucket: Identifiable {
    let interval: DateInterval
    let primaryBytes: Double?
    let secondaryBytes: Double?
    let connectedSeconds: Double?
    let peakConnections: Int?

    var id: Date { interval.start }
}

struct MenuTrafficReport {
    let interval: DateInterval
    let buckets: [MenuTrafficBucket]
    let primaryBytes: Double?
    let secondaryBytes: Double?
    let updatedAt: Date?
    let coverage: Double?

    static func local(
        range: MenuTrafficRange, entries: [TrafficHistoryEntry], now: Date = .now, calendar: Calendar = .current
    ) -> Self {
        let period = UsagePeriod(range: range.usageRange, now: now, calendar: calendar)
        let report = UsageReport(period: period, entries: entries)
        let buckets = report.buckets(in: report.rootScope).map { bucket in
            let totals = bucket.totals
            let hasTraffic = hasTrafficReadings(totals)
            return MenuTrafficBucket(
                interval: bucket.interval,
                primaryBytes: hasTraffic ? totals.downloaded : nil,
                secondaryBytes: hasTraffic ? totals.uploaded : nil,
                connectedSeconds: totals.hasRecords || hasTraffic ? totals.connectedSeconds : nil,
                peakConnections: totals.samples > 0 || totals.peakConnections > 0 ? totals.peakConnections : nil
            )
        }
        let totals = report.totals
        let hasTraffic = hasTrafficReadings(totals)
        return Self(
            interval: period.current,
            buckets: buckets,
            primaryBytes: hasTraffic ? totals.downloaded : nil,
            secondaryBytes: hasTraffic ? totals.uploaded : nil,
            updatedAt: nil,
            coverage: nil
        )
    }

    static func digitalOcean(
        range: MenuTrafficRange, report: DigitalOceanBandwidthReport, updatedAt: Date?, calendar: Calendar = .current
    ) -> Self {
        let requested = range.interval(now: report.until)
        let window = DateInterval(start: max(requested.start, report.from), end: report.until)
        let granularity = range.usageRange.granularity.component
        var buckets: [MenuTrafficBucket] = []
        var cursor = window.start
        while cursor < window.end,
              let calendarBucket = calendar.dateInterval(of: granularity, for: cursor),
              calendarBucket.end > cursor {
            let interval = DateInterval(start: cursor, end: min(calendarBucket.end, window.end))
            buckets.append(MenuTrafficBucket(
                interval: interval,
                primaryBytes: report.inbound.estimate(in: interval).estimatedBytes,
                secondaryBytes: report.outbound.estimate(in: interval).estimatedBytes,
                connectedSeconds: nil,
                peakConnections: nil
            ))
            cursor = interval.end
        }
        let inbound = report.inbound.estimate(in: window)
        let outbound = report.outbound.estimate(in: window)
        let coveredFraction = window.duration > 0
            ? min(1, (inbound.coveredSeconds + outbound.coveredSeconds) / (2 * window.duration))
            : 0
        return Self(
            interval: window,
            buckets: buckets,
            primaryBytes: inbound.estimatedBytes,
            secondaryBytes: outbound.estimatedBytes,
            updatedAt: updatedAt,
            coverage: coveredFraction
        )
    }

    private static func hasTrafficReadings(_ totals: UsageTotals) -> Bool {
        totals.samples > 0 || totals.downloaded > 0 || totals.uploaded > 0
    }
}
