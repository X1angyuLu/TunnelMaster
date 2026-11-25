import Foundation
import TunnelMasterCore

enum MenuTrafficRange: String, CaseIterable, Identifiable {
    case day, week, fortnight, month

    var id: Self { self }
    var title: String { self == .fortnight ? "14 天" : usageRange.rawValue }
    var days: Int { self == .fortnight ? 14 : usageRange.dayCount }

    func interval(now: Date) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-Double(days) * 86_400), end: now)
    }

    func localInterval(now: Date, calendar: Calendar = .current) -> DateInterval {
        let period = UsagePeriod(range: usageRange, now: now, calendar: calendar)
        return localInterval(in: period, now: now)
    }

    fileprivate func localInterval(in period: UsagePeriod, now: Date) -> DateInterval {
        guard self == .fortnight else { return period.current }
        let today = period.calendar.startOfDay(for: now)
        let start = period.calendar.date(byAdding: .day, value: 1 - days, to: today) ?? today
        return DateInterval(start: start, end: period.current.end)
    }

    fileprivate var usageRange: UsageRange {
        switch self {
        case .day: .day
        case .week: .week
        case .fortnight, .month: .month
        }
    }
}

struct MenuTrafficBucket: Identifiable {
    let interval: DateInterval
    let primaryBytes: Double?
    let secondaryBytes: Double?
    let connectedSeconds: Double?
    let peakConnections: Int?
    let peakPrimaryRate: Double?
    let peakSecondaryRate: Double?
    let sessionsStarted: Int?
    let coverage: Double?

    var id: Date { interval.start }

    init(
        interval: DateInterval, primaryBytes: Double?, secondaryBytes: Double?, connectedSeconds: Double?,
        peakConnections: Int?, peakPrimaryRate: Double? = nil, peakSecondaryRate: Double? = nil,
        sessionsStarted: Int? = nil, coverage: Double? = nil
    ) {
        self.interval = interval
        self.primaryBytes = primaryBytes
        self.secondaryBytes = secondaryBytes
        self.connectedSeconds = connectedSeconds
        self.peakConnections = peakConnections
        self.peakPrimaryRate = peakPrimaryRate
        self.peakSecondaryRate = peakSecondaryRate
        self.sessionsStarted = sessionsStarted
        self.coverage = coverage
    }
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
        let window = range.localInterval(in: period, now: now)
        let report = UsageReport(
            period: period, entries: entries.filter { $0.timestamp >= window.start && $0.timestamp < window.end }
        )
        let scope = UsageBucketScope(interval: window, granularity: range.usageRange.granularity)
        let buckets = report.buckets(in: scope).map { bucket in
            let totals = bucket.totals
            let hasTraffic = hasTrafficReadings(totals)
            let hasRecords = totals.hasRecords || hasTraffic || totals.peakConnections > 0
            return MenuTrafficBucket(
                interval: bucket.interval,
                primaryBytes: hasTraffic ? totals.downloaded : nil,
                secondaryBytes: hasTraffic ? totals.uploaded : nil,
                connectedSeconds: hasRecords ? totals.connectedSeconds : nil,
                peakConnections: totals.samples > 0 || totals.peakConnections > 0 ? totals.peakConnections : nil,
                peakPrimaryRate: totals.samples > 0 || totals.peakDownloadRate > 0 ? totals.peakDownloadRate : nil,
                peakSecondaryRate: totals.samples > 0 || totals.peakUploadRate > 0 ? totals.peakUploadRate : nil,
                sessionsStarted: hasRecords ? totals.sessionsStarted : nil
            )
        }
        let totals = report.totals
        let hasTraffic = hasTrafficReadings(totals)
        return Self(
            interval: window,
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
            let inbound = report.inbound.estimate(in: interval)
            let outbound = report.outbound.estimate(in: interval)
            let includesEnd = interval.end == window.end
            buckets.append(MenuTrafficBucket(
                interval: interval,
                primaryBytes: inbound.estimatedBytes,
                secondaryBytes: outbound.estimatedBytes,
                connectedSeconds: nil,
                peakConnections: nil,
                peakPrimaryRate: peakSampleRate(report.inbound, in: interval, includesEnd: includesEnd),
                peakSecondaryRate: peakSampleRate(report.outbound, in: interval, includesEnd: includesEnd),
                coverage: fractionCovered(
                    inboundSeconds: inbound.coveredSeconds, outboundSeconds: outbound.coveredSeconds, in: interval
                )
            ))
            cursor = interval.end
        }
        let inbound = report.inbound.estimate(in: window)
        let outbound = report.outbound.estimate(in: window)
        return Self(
            interval: window,
            buckets: buckets,
            primaryBytes: inbound.estimatedBytes,
            secondaryBytes: outbound.estimatedBytes,
            updatedAt: updatedAt,
            coverage: fractionCovered(
                inboundSeconds: inbound.coveredSeconds, outboundSeconds: outbound.coveredSeconds, in: window
            )
        )
    }

    private static func hasTrafficReadings(_ totals: UsageTotals) -> Bool {
        totals.samples > 0 || totals.downloaded > 0 || totals.uploaded > 0
    }

    private static func peakSampleRate(
        _ series: DigitalOceanBandwidthSeries, in interval: DateInterval, includesEnd: Bool
    ) -> Double? {
        let samples = series.samples.lazy.filter {
            $0.timestamp >= interval.start && ($0.timestamp < interval.end || (includesEnd && $0.timestamp == interval.end))
        }
        guard let peakMbps = samples.map(\.mbps).max() else { return nil }
        let bytesPerSecond = peakMbps * 125_000
        return bytesPerSecond.isFinite ? bytesPerSecond : nil
    }

    private static func fractionCovered(
        inboundSeconds: TimeInterval, outboundSeconds: TimeInterval, in interval: DateInterval
    ) -> Double {
        guard interval.duration > 0 else { return 0 }
        return min(1, (inboundSeconds + outboundSeconds) / (2 * interval.duration))
    }
}
