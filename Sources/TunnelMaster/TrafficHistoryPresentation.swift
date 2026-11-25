import Foundation
import TunnelMasterCore

enum UsageRange: String, CaseIterable, Identifiable {
    case day = "24 小时"
    case week = "7 天"
    case month = "30 天"
    case quarter = "90 天"
    case year = "1 年"

    var id: Self { self }

    var dayCount: Int {
        switch self {
        case .day: 1
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .year: 365
        }
    }

    var granularity: UsageGranularity {
        switch self {
        case .day: .hour
        case .week, .month: .day
        case .quarter: .week
        case .year: .month
        }
    }
}

enum UsageGranularity {
    case hour, day, week, month

    var component: Calendar.Component {
        switch self {
        case .hour: .hour
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    var title: String {
        switch self {
        case .hour: "按小时"
        case .day: "按天"
        case .week: "按周"
        case .month: "按月"
        }
    }

    var finer: Self? {
        switch self {
        case .hour: nil
        case .day: .hour
        case .week, .month: .day
        }
    }

    func axisLabel(_ date: Date) -> String {
        switch self {
        case .hour:
            date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(UsageFormat.locale))
        case .day, .week:
            date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).locale(UsageFormat.locale))
        case .month:
            date.formatted(.dateTime.month(.abbreviated).locale(UsageFormat.locale))
        }
    }

    func title(for interval: DateInterval) -> String {
        switch self {
        case .hour:
            "\(UsageFormat.date(interval.start)) · \(axisLabel(interval.start))"
        case .day:
            UsageFormat.date(interval.start)
        case .week:
            "\(UsageFormat.date(interval.start)) – \(UsageFormat.date(interval.end.addingTimeInterval(-1)))"
        case .month:
            interval.start.formatted(.dateTime.year().month(.wide).locale(UsageFormat.locale))
        }
    }
}

struct UsagePeriod {
    let range: UsageRange
    let current: DateInterval
    let previous: DateInterval
    let calendar: Calendar

    init(range: UsageRange, now: Date, calendar: Calendar = .current) {
        self.range = range
        self.calendar = calendar
        let quarter: TimeInterval = 15 * 60
        let time = now.timeIntervalSinceReferenceDate
        let sampledUntil = Date(timeIntervalSinceReferenceDate: (floor(time / quarter) + 1) * quarter)

        if range == .day {
            current = DateInterval(start: sampledUntil.addingTimeInterval(-86_400), end: sampledUntil)
            previous = DateInterval(start: current.start.addingTimeInterval(-86_400), end: current.start)
        } else {
            let today = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: 1 - range.dayCount, to: today) ?? today
            let previousStart = calendar.date(byAdding: .day, value: -range.dayCount, to: start) ?? start
            let previousEnd = calendar.date(byAdding: .day, value: -range.dayCount, to: sampledUntil) ?? start
            current = DateInterval(start: start, end: sampledUntil)
            previous = DateInterval(start: previousStart, end: min(start, previousEnd))
        }
    }
}

struct UsageTotals {
    var downloaded: Double = 0
    var uploaded: Double = 0
    var connectedSeconds: Double = 0
    var peakDownloadRate: Double = 0
    var peakUploadRate: Double = 0
    var sessionsStarted = 0
    var peakConnections = 0
    var samples = 0

    var total: Double { downloaded + uploaded }
    var hasRecords: Bool { samples > 0 || connectedSeconds > 0 || sessionsStarted > 0 }
    var downloadShare: Double { total > 0 ? downloaded / total : 0 }

    mutating func add(_ entry: TrafficHistoryEntry) {
        downloaded += Double(entry.downloaded)
        uploaded += Double(entry.uploaded)
        connectedSeconds += entry.connectedSeconds
        peakDownloadRate = max(peakDownloadRate, entry.peakDownloadRate)
        peakUploadRate = max(peakUploadRate, entry.peakUploadRate)
        sessionsStarted += entry.sessionsStarted
        peakConnections = max(peakConnections, entry.peakConnections)
        samples += entry.samples
    }
}

struct UsageBucket: Identifiable {
    let interval: DateInterval
    let granularity: UsageGranularity
    var totals = UsageTotals()

    var id: Date { interval.start }
    var label: String { granularity.title(for: interval) }
    var midpoint: Date { interval.start.addingTimeInterval(interval.duration / 2) }
}

struct UsageBucketScope: Equatable {
    let interval: DateInterval
    let granularity: UsageGranularity
}

struct UsageReport {
    let period: UsagePeriod
    private let entries: [TrafficHistoryEntry]
    private let rootBuckets: [UsageBucket]
    let totals: UsageTotals
    let previous: UsageTotals
    let observedDays: Int
    let rootScope: UsageBucketScope

    init(period: UsagePeriod, entries: [TrafficHistoryEntry]) {
        self.period = period
        var current: [TrafficHistoryEntry] = []
        var currentTotals = UsageTotals()
        var previousTotals = UsageTotals()
        var days = 0
        var nextDay: Date?
        for entry in entries.sorted(by: { $0.timestamp < $1.timestamp }) {
            if entry.timestamp >= period.current.start, entry.timestamp < period.current.end {
                current.append(entry)
                currentTotals.add(entry)
                if entry.samples > 0, nextDay.map({ entry.timestamp >= $0 }) ?? true {
                    days += 1
                    nextDay = period.calendar.dateInterval(of: .day, for: entry.timestamp)?.end
                }
            } else if entry.timestamp >= period.previous.start, entry.timestamp < period.previous.end {
                previousTotals.add(entry)
            }
        }
        self.entries = current
        totals = currentTotals
        previous = previousTotals
        observedDays = days
        let scope = UsageBucketScope(interval: period.current, granularity: period.range.granularity)
        rootScope = scope
        rootBuckets = Self.makeBuckets(in: scope, from: current, calendar: period.calendar)
    }

    func buckets(in scope: UsageBucketScope) -> [UsageBucket] {
        scope == rootScope ? rootBuckets : Self.makeBuckets(in: scope, from: entries, calendar: period.calendar)
    }

    private static func makeBuckets(in scope: UsageBucketScope, from entries: [TrafficHistoryEntry], calendar: Calendar) -> [UsageBucket] {
        var result: [UsageBucket] = []
        var next = scope.interval.start
        while next < scope.interval.end,
              let whole = calendar.dateInterval(of: scope.granularity.component, for: next), whole.end > next {
            let end = min(whole.end, scope.interval.end)
            result.append(UsageBucket(
                interval: DateInterval(start: next, end: end),
                granularity: scope.granularity
            ))
            next = end
        }

        var index = 0
        for entry in entries where entry.timestamp >= scope.interval.start {
            while index < result.count, entry.timestamp >= result[index].interval.end {
                index += 1
            }
            guard index < result.count else { break }
            result[index].totals.add(entry)
        }
        return result
    }
}

enum UsageFormat {
    static let locale = Locale(identifier: "zh_Hans_CN")

    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().locale(locale))
    }

    static func fullDate(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day().locale(locale))
    }

    static func bytes(_ bytes: Double) -> String {
        let count = Int64(exactly: bytes.rounded()) ?? .max
        return count.formatted(.byteCount(style: .file, spellsOutZero: false))
    }

    static func rate(_ bytesPerSecond: Double) -> String { "\(bytes(bytesPerSecond))/s" }

    static func duration(_ seconds: Double) -> String {
        guard seconds >= 60 else { return seconds > 0 ? "不足 1 分钟" : "0 分钟" }
        let minutes = Int(seconds / 60)
        let hours = minutes / 60
        if hours >= 24 { return "\(hours / 24) 天 \(hours % 24) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes % 60) 分钟" }
        return "\(minutes) 分钟"
    }
}
