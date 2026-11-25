import Charts
import SwiftUI

@MainActor
struct MenuHistoryCard: View {
    let report: MenuTrafficReport?
    let range: MenuTrafficRange
    let isServer: Bool
    let isLoading: Bool
    let errorMessage: String?
    @StateObject private var selection = MenuChartSelection()

    private var primaryLabel: String { isServer ? "公网入站" : "下载" }
    private var secondaryLabel: String { isServer ? "公网出站" : "上传" }
    private var granularity: UsageGranularity { range == .day ? .hour : .day }

    var body: some View {
        let buckets = report?.buckets ?? []
        let selected = buckets.first { $0.id == selection.active }
            ?? buckets.last { Self.hasData($0) }
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                MenuMetricTile(title: primaryLabel, icon: "arrow.down", label: report?.primaryBytes.map(UsageFormat.bytes) ?? "—",
                               detail: isServer ? "按采样估算" : "所选时段合计", color: .teal)
                Divider().frame(height: 43)
                MenuMetricTile(title: secondaryLabel, icon: "arrow.up", label: report?.secondaryBytes.map(UsageFormat.bytes) ?? "—",
                               detail: isServer ? "按采样估算" : "所选时段合计", color: .purple)
            }
            Group {
                if let report, buckets.contains(where: Self.hasData) {
                    historyChart(report, selected: selected)
                } else {
                    placeholder
                }
            }
            .frame(height: 77)

            MenuChartInspector(
                timestamp: selected.map { granularity.title(for: $0.interval) } ?? "—",
                primary: selected?.primaryBytes.map(UsageFormat.bytes) ?? "—",
                secondary: selected?.secondaryBytes.map(UsageFormat.bytes) ?? "—",
                primaryLabel: primaryLabel, secondaryLabel: secondaryLabel,
                dates: selected == nil ? [] : buckets.map(\.id), selected: selected?.id, selection: selection
            )
            Divider()
            footer(selected)
        }
        .modifier(MenuTrafficFrame())
        .onDisappear { selection.hover(nil) }
    }

    private var placeholder: some View {
        HStack(spacing: 7) {
            if isLoading {
                ProgressView().controlSize(.small)
                Text("读取\(isServer ? "服务器" : "本机")流量…")
            } else if errorMessage != nil {
                Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
                Text("暂时无法读取流量")
            } else {
                Image(systemName: "chart.bar.xaxis").accessibilityHidden(true)
                Text("此时段暂无采样")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
    }

    private func footer(_ bucket: MenuTrafficBucket?) -> some View {
        HStack(spacing: 8) {
            if let errorMessage {
                Label(report == nil ? errorMessage : "更新失败 · 显示上次结果", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(errorMessage)
            } else if isLoading {
                Text("正在刷新…")
            } else if isServer {
                if let coverage = report?.coverage {
                    Text("覆盖 \(coverage.formatted(.percent.precision(.fractionLength(0))))")
                } else {
                    Text("公网监控采样")
                }
                Spacer(minLength: 0)
                if let updatedAt = report?.updatedAt {
                    Text("获取于 \(MenuChartSelection.time(updatedAt, seconds: false))")
                }
            } else if let bucket {
                if let seconds = bucket.connectedSeconds {
                    Label(UsageFormat.duration(seconds), systemImage: "clock")
                        .accessibilityLabel("连接时长 \(UsageFormat.duration(seconds))")
                }
                Spacer(minLength: 0)
                if let count = bucket.peakConnections {
                    Text("活跃连接峰值 \(count.formatted())")
                }
            } else {
                Text("连接后记录本机流量")
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 14, alignment: .leading)
    }

    private func historyChart(_ report: MenuTrafficReport, selected: MenuTrafficBucket?) -> some View {
        let maximum = report.buckets.map { ($0.primaryBytes ?? 0) + ($0.secondaryBytes ?? 0) }.max() ?? 0
        let upperBound = max(1, maximum * 1.08)
        return Chart {
            ForEach(report.buckets) { bucket in
                bucketMarks(bucket, selected: bucket.id == selected?.id)
            }
            if let selected {
                RuleMark(x: .value("检查时段", Self.center(selected)))
                    .foregroundStyle(.secondary.opacity(0.42))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
        }
        .chartXScale(domain: report.interval.start...report.interval.end)
        .chartYScale(domain: 0...upperBound)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(granularity.axisLabel(date)).font(.caption2.monospacedDigit())
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, upperBound / 2, upperBound]) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.16))
            }
        }
        .chartOverlay { chart in
            MenuChartInteraction(chart: chart, selection: selection) { date in
                report.buckets.first { date >= $0.interval.start && date < $0.interval.end }?.id
            }
        }
        .accessibilityLabel("\(primaryLabel)与\(secondaryLabel)趋势")
        .accessibilityAdjustableAction { direction in
            selection.step(direction, from: selected?.id, across: report.buckets.map(\.id))
        }
    }

    @ChartContentBuilder
    private func bucketMarks(_ bucket: MenuTrafficBucket, selected: Bool) -> some ChartContent {
        let margin = bucket.interval.duration * 0.14
        let start = bucket.interval.start.addingTimeInterval(margin)
        let end = bucket.interval.end.addingTimeInterval(-margin)
        let primary = bucket.primaryBytes ?? 0
        let opacity = selected ? 1.0 : 0.73
        if let bytes = bucket.primaryBytes, bytes > 0 {
            RectangleMark(xStart: .value("开始", start), xEnd: .value("结束", end),
                          yStart: .value("流量", 0.0), yEnd: .value(primaryLabel, bytes))
                .foregroundStyle(Color.teal.opacity(opacity))
        }
        if let bytes = bucket.secondaryBytes, bytes > 0 {
            RectangleMark(xStart: .value("开始", start), xEnd: .value("结束", end),
                          yStart: .value("流量", primary), yEnd: .value(secondaryLabel, primary + bytes))
                .foregroundStyle(Color.purple.opacity(opacity))
        }
        if Self.hasData(bucket), primary + (bucket.secondaryBytes ?? 0) == 0 {
            PointMark(x: .value("时间", Self.center(bucket)), y: .value("流量", 0.0))
                .foregroundStyle(.secondary.opacity(0.7)).symbolSize(9)
        }
    }

    private static func center(_ bucket: MenuTrafficBucket) -> Date {
        bucket.interval.start.addingTimeInterval(bucket.interval.duration / 2)
    }

    private static func hasData(_ bucket: MenuTrafficBucket) -> Bool {
        bucket.primaryBytes != nil || bucket.secondaryBytes != nil
    }
}

struct MenuTrafficFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 222, alignment: .topLeading)
            .background(.quaternary.opacity(0.41), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.quaternary).allowsHitTesting(false))
    }
}

struct MenuMetricTile: View {
    let title: String
    let icon: String
    let label: String
    let detail: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(detail)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

@MainActor
final class MenuChartSelection: ObservableObject {
    @Published private(set) var hovered: Date?
    @Published private(set) var pinned: Date?

    var active: Date? { hovered ?? pinned }

    func hover(_ date: Date?) {
        if hovered != date { hovered = date }
    }

    func togglePin(_ date: Date) {
        pinned = pinned == date ? nil : date
    }

    func clearPin() { pinned = nil }

    func neighbour(from date: Date?, across dates: [Date], offset: Int) -> Date? {
        guard let date, let index = dates.firstIndex(of: date), dates.indices.contains(index + offset) else { return nil }
        return dates[index + offset]
    }

    func step(_ direction: AccessibilityAdjustmentDirection, from date: Date?, across dates: [Date]) {
        if let next = neighbour(from: date, across: dates, offset: direction == .increment ? 1 : -1) {
            pin(next)
        }
    }

    func pin(_ date: Date) {
        hover(nil)
        pinned = date
    }

    static func time(_ date: Date, seconds: Bool) -> String {
        let hoursAndMinutes = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        return date.formatted((seconds ? hoursAndMinutes.second(.twoDigits) : hoursAndMinutes).locale(UsageFormat.locale))
    }
}

@MainActor
struct MenuChartInteraction: View {
    let chart: ChartProxy
    let selection: MenuChartSelection
    let pick: (Date) -> Date?

    var body: some View {
        GeometryReader { geometry in
            let frame = geometry[chart.plotAreaFrame]
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .background {
                    MenuChartPointer { point in
                        selection.hover(point.flatMap { selectedDate(at: $0, inside: frame) })
                    }
                }
                .gesture(SpatialTapGesture().onEnded { tap in
                    if let date = selectedDate(at: tap.location, inside: frame) {
                        selection.togglePin(date)
                    }
                })
                .accessibilityHidden(true)
        }
    }

    private func selectedDate(at location: CGPoint, inside frame: CGRect) -> Date? {
        guard frame.contains(location), let date: Date = chart.value(atX: location.x - frame.minX) else { return nil }
        return pick(date)
    }
}

@MainActor
struct MenuChartInspector: View {
    let timestamp: String
    let primary: String
    let secondary: String
    let primaryLabel: String
    let secondaryLabel: String
    let dates: [Date]
    let selected: Date?
    @ObservedObject var selection: MenuChartSelection

    var body: some View {
        HStack(spacing: 7) {
            Text(timestamp)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.74)
                .frame(minWidth: 48, alignment: .leading)

            HStack(spacing: 7) {
                reading(primary, title: primaryLabel, symbol: "arrow.down", color: .teal)
                reading(secondary, title: secondaryLabel, symbol: "arrow.up", color: .purple)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)

            HStack(spacing: 3) {
                stepButton(offset: -1, title: "查看更早采样", icon: "chevron.left")
                stepButton(offset: 1, title: "查看更新采样", icon: "chevron.right")
                Button {
                    if selection.pinned != nil {
                        selection.clearPin()
                    } else if let selected {
                        selection.pin(selected)
                    }
                } label: {
                    Image(systemName: selection.pinned == nil ? "pin" : "pin.fill").frame(width: 15, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(selected == nil)
                .accessibilityLabel(selection.pinned == nil ? "固定当前读数" : "取消固定读数")
                .help(selection.pinned == nil ? "固定当前读数" : "取消固定读数")
            }
        }
        .font(.caption2.monospacedDigit())
        .padding(.horizontal, 6)
        .frame(height: 23)
        .background(.quaternary.opacity(0.36), in: RoundedRectangle(cornerRadius: 6))
    }

    private func reading(_ value: String, title: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            Text(value).fontWeight(.semibold).lineLimit(1).minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value)")
    }

    private func stepButton(offset: Int, title: String, icon: String) -> some View {
        let next = selection.neighbour(from: selected, across: dates, offset: offset)
        return Button {
            if let next { selection.pin(next) }
        } label: {
            Image(systemName: icon).frame(width: 15, height: 20)
        }
        .buttonStyle(.borderless)
        .disabled(next == nil)
        .help(title)
        .accessibilityLabel(title)
    }
}
