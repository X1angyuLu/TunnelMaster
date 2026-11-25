import AppKit
import Charts
import SwiftUI

@MainActor
struct UsageHistoryView: View {
    @ObservedObject var store: TunnelStore
    private static let sourceKey = "usageHistorySource"
    @AppStorage(UsageHistoryView.sourceKey) private var sourcePreference = ""
    @AppStorage("usageHistoryRange") private var range = UsageRange.week
    @StateObject private var state = UsageHistoryWindowState()

    private static let downloadColor = Color.teal
    private static let uploadColor = Color.purple

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch historySource.wrappedValue {
            case .local:
                localHistory
            case .digitalOcean:
                DigitalOceanUsageView(source: store.digitalOcean)
            }
        }
        .frame(minWidth: 760, minHeight: 610)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    static func selectDigitalOcean() {
        UserDefaults.standard.set(HistoryDataSource.digitalOcean.rawValue, forKey: sourceKey)
    }

    private var localHistory: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if store.historySaveIssue {
                    Label("最近的流量记录暂未保存", systemImage: "exclamationmark.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                }
                if state.loadFailed {
                    loadError
                }
                if let report = state.report, report.period.range == range, report.totals.hasRecords {
                    analytics(report)
                } else if state.report?.period.range == range, !state.loadFailed {
                    emptyState
                } else if !state.loadFailed {
                    ProgressView("正在读取流量记录…")
                        .frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(22)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .task(id: LoadRequest(range: range, revision: store.historyRevision, retry: state.retry)) {
            await load()
        }
        .onChange(of: range) { _ in
            state.selectedDate = nil
            state.hoveredDate = nil
            state.scopes = []
            state.loadFailed = false
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("流量统计")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                Text(historySubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
            Picker("数据来源", selection: historySource) {
                ForEach(HistoryDataSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 155)

            if historySource.wrappedValue == .local {
                Picker("统计时间范围", selection: $range) {
                    ForEach(UsageRange.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 305)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(.regularMaterial)
    }

    private var historySource: Binding<HistoryDataSource> {
        Binding {
            HistoryDataSource(rawValue: sourcePreference) ?? (store.digitalOcean.dropletID == nil ? .local : .digitalOcean)
        } set: { sourcePreference = $0.rawValue }
    }

    private var historySubtitle: String {
        if historySource.wrappedValue == .digitalOcean { return "整台 Droplet 的公网流量" }
        return state.report.flatMap { $0.period.range == range ? periodLabel($0.period) : nil } ?? "这台 Mac 的接管流量"
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 37, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("此时间段暂无流量记录")
                .font(.title3.weight(.semibold))
            Text("连接 TunnelMaster 后开始记录。你也可以切换时间范围查看较早的记录。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 315)
        .padding(.horizontal, 32)
    }

    private var loadError: some View {
        HStack {
            Label("无法读取本机流量记录", systemImage: "exclamationmark.circle")
            Spacer()
            Button("重试") { state.retry += 1 }
        }
        .padding(14)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }

    private func analytics(_ report: UsageReport) -> some View {
        let scope = chartScope(report)
        let buckets = report.buckets(in: scope)
        let selection = selectedBucket(in: buckets)
        return VStack(alignment: .leading, spacing: 16) {
            overview(report)
            sessions(report)
            historyChart(scope: scope, buckets: buckets, selected: selection, calendar: report.period.calendar)

            HStack(alignment: .top, spacing: 12) {
                rates(report.totals)
                busyPeriods(buckets)
            }

            Text("统计范围为 Mihomo 处理的直连与隧道流量。历史记录保存在本机，空白时段表示没有记录。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func overview(_ report: UsageReport) -> some View {
        let totals = report.totals
        return HStack(spacing: 25) {
            VStack(alignment: .leading, spacing: 6) {
                Text("合计流量")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(trafficAmount(totals, bytes: totals.total))
                    .font(.system(size: 35, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(comparison(report))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: 350, alignment: .leading)

            Divider()
                .frame(height: 64)

            VStack(spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    direction("下载", symbol: "arrow.down", color: Self.downloadColor,
                              amount: trafficAmount(totals, bytes: totals.downloaded),
                              percentage: totals.total > 0 ? totals.downloadShare : nil)
                    Spacer(minLength: 15)
                    direction("上传", symbol: "arrow.up", color: Self.uploadColor,
                              amount: trafficAmount(totals, bytes: totals.uploaded),
                              percentage: totals.total > 0 ? 1 - totals.downloadShare : nil)
                }
                GeometryReader { proxy in
                    let width = proxy.size.width * totals.downloadShare
                    HStack(spacing: 0) {
                        Rectangle().fill(Self.downloadColor).frame(width: width)
                        Rectangle().fill(Self.uploadColor)
                    }
                    .opacity(totals.total > 0 ? 1 : 0)
                    .background(.quaternary)
                    .clipShape(Capsule())
                }
                .frame(height: 7)
                .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(18)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.accentColor.opacity(0.14)))
    }

    private func direction(_ name: String, symbol: String, color: Color, amount: String, percentage: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(name, systemImage: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(amount)
                    .font(.system(.title3, design: .rounded, weight: .semibold).monospacedDigit())
                if let percentage {
                    Text(percentage.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.72)
        }
        .accessibilityElement(children: .combine)
    }

    private func sessions(_ report: UsageReport) -> some View {
        let totals = report.totals
        return HStack(spacing: 12) {
            statTile("累计连接时长", symbol: "clock", value: UsageFormat.duration(totals.connectedSeconds))
            statTile("发起连接", symbol: "bolt.horizontal", value: "\(totals.sessionsStarted.formatted()) 次")
            statTile("活跃连接峰值", symbol: "point.3.connected.trianglepath.dotted",
                     value: totals.samples > 0 ? "\(totals.peakConnections.formatted()) 个" : "—")
            statTile("有采样的天数", symbol: "calendar", value: "\(report.observedDays.formatted()) 天")
        }
    }

    private func statTile(_ title: String, symbol: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .modifier(UsagePanel(inset: 13))
    }

    private func historyChart(scope: UsageBucketScope, buckets: [UsageBucket], selected: UsageBucket?, calendar: Calendar) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("流量趋势")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(scope.granularity.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                legend("下载", color: Self.downloadColor)
                legend("上传", color: Self.uploadColor)
                if !state.scopes.isEmpty {
                    Button {
                        state.scopes.removeLast()
                        state.selectedDate = nil
                        state.hoveredDate = nil
                    } label: {
                        Label("返回", systemImage: "chevron.backward")
                    }
                    .controlSize(.small)
                    .accessibilityLabel("返回上一级统计")
                }
            }

            bucketChart(scope: scope, buckets: buckets, selected: selected)
                .frame(height: 170)

            Divider()

            if let selected {
                inspector(selected, calendar: calendar)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(UsagePanel(inset: 16))
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(title)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func bucketChart(scope: UsageBucketScope, buckets: [UsageBucket], selected: UsageBucket?) -> some View {
        let peak = buckets.map(\.totals.total).max() ?? 0
        return Chart {
            ForEach(buckets) { bucket in
                if bucket.totals.samples > 0 {
                    bucketMarks(bucket, isSelected: bucket.id == selected?.id)
                }
            }
            if let selected {
                RuleMark(x: .value("选中时段", selected.midpoint))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXScale(domain: scope.interval.start...scope.interval.end)
        .chartYScale(domain: 0...max(1, peak * 1.07))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisTick().foregroundStyle(.secondary.opacity(0.3))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(scope.granularity.axisLabel(date))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                AxisValueLabel {
                    if let bytes = value.as(Double.self) {
                        Text(UsageFormat.bytes(bytes))
                    }
                }
            }
        }
        .chartOverlay { chart in chartSelection(chart, buckets: buckets) }
        .accessibilityLabel("各时段下载和上传总量")
        .accessibilityAdjustableAction { direction in
            guard let selected, let index = buckets.firstIndex(where: { $0.id == selected.id }) else { return }
            let offset = direction == .increment ? 1 : -1
            if buckets.indices.contains(index + offset) {
                state.selectedDate = buckets[index + offset].id
            }
        }
    }

    @ChartContentBuilder
    private func bucketMarks(_ bucket: UsageBucket, isSelected: Bool) -> some ChartContent {
        let margin = bucket.interval.duration * 0.14
        let start = bucket.interval.start.addingTimeInterval(margin)
        let end = bucket.interval.end.addingTimeInterval(-margin)
        let opacity = isSelected ? 1.0 : 0.8
        RectangleMark(
            xStart: .value("开始", start), xEnd: .value("结束", end),
            yStart: .value("流量", 0.0), yEnd: .value("流量", bucket.totals.downloaded)
        )
        .foregroundStyle(Self.downloadColor.opacity(opacity))

        RectangleMark(
            xStart: .value("开始", start), xEnd: .value("结束", end),
            yStart: .value("流量", bucket.totals.downloaded), yEnd: .value("流量", bucket.totals.total)
        )
        .foregroundStyle(Self.uploadColor.opacity(opacity))
    }

    private func chartSelection(_ chart: ChartProxy, buckets: [UsageBucket]) -> some View {
        GeometryReader { geometry in
            let frame = geometry[chart.plotAreaFrame]
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                    if let date = bucketDate(at: gesture.location, inside: frame, chart: chart, buckets: buckets) {
                        state.selectedDate = date
                    }
                })
                .onContinuousHover { phase in
                    let date: Date?
                    switch phase {
                    case .active(let location):
                        date = bucketDate(at: location, inside: frame, chart: chart, buckets: buckets)
                    case .ended:
                        date = nil
                    }
                    if state.hoveredDate != date { state.hoveredDate = date }
                }
                .accessibilityHidden(true)
        }
    }

    private func bucketDate(at location: CGPoint, inside frame: CGRect, chart: ChartProxy, buckets: [UsageBucket]) -> Date? {
        guard frame.contains(location), let date: Date = chart.value(atX: location.x - frame.minX) else { return nil }
        return buckets.first { date >= $0.interval.start && date < $0.interval.end }?.id
    }

    private func inspector(_ bucket: UsageBucket, calendar: Calendar) -> some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(bucket.label)
                    .font(.callout.weight(.semibold))
                if bucket.granularity == .hour {
                    Text(bucket.interval.start, format: .dateTime.timeZone(.iso8601(.short)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if bucket.totals.hasRecords {
                dataPoint("下载", value: trafficAmount(bucket.totals, bytes: bucket.totals.downloaded))
                dataPoint("上传", value: trafficAmount(bucket.totals, bytes: bucket.totals.uploaded))
                dataPoint("合计", value: trafficAmount(bucket.totals, bytes: bucket.totals.total))
                dataPoint("连接时长", value: UsageFormat.duration(bucket.totals.connectedSeconds))
            } else {
                Text("该时段暂无记录")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if bucket.totals.hasRecords, let finer = bucket.granularity.finer,
               let whole = calendar.dateInterval(of: bucket.granularity.component, for: bucket.interval.start) {
                Button {
                    state.scopes.append(UsageBucketScope(interval: whole, granularity: finer))
                    state.selectedDate = nil
                    state.hoveredDate = nil
                } label: {
                    Label(finer == .hour ? "查看逐小时" : "查看逐日", systemImage: "magnifyingglass")
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 37, alignment: .leading)
    }

    private func rates(_ totals: UsageTotals) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("速率表现").font(.headline).accessibilityAddTraits(.isHeader)
            Grid(alignment: .leading, horizontalSpacing: 25, verticalSpacing: 13) {
                GridRow {
                    Text(" ").accessibilityHidden(true)
                    legend("下载", color: Self.downloadColor)
                    legend("上传", color: Self.uploadColor)
                }
                GridRow {
                    Text("连接期间平均").foregroundStyle(.secondary)
                    speed(totals.downloaded / max(1, totals.connectedSeconds),
                          available: totals.samples > 0 && totals.connectedSeconds >= 1)
                    speed(totals.uploaded / max(1, totals.connectedSeconds),
                          available: totals.samples > 0 && totals.connectedSeconds >= 1)
                }
                GridRow {
                    Text("采样峰值").foregroundStyle(.secondary)
                    speed(totals.peakDownloadRate, available: totals.samples > 0)
                    speed(totals.peakUploadRate, available: totals.samples > 0)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(UsagePanel(inset: 16))
    }

    private func speed(_ value: Double, available: Bool) -> some View {
        Text(available ? UsageFormat.rate(value) : "—")
            .fontWeight(.medium)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func busyPeriods(_ buckets: [UsageBucket]) -> some View {
        let busiest = buckets.filter { $0.totals.samples > 0 && $0.totals.total > 0 }
            .sorted { $0.totals.total > $1.totals.total }.prefix(4)
        return VStack(alignment: .leading, spacing: 9) {
            Text("流量最多的时段").font(.headline).accessibilityAddTraits(.isHeader)
            if busiest.isEmpty {
                Text("暂无流量排名").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(busiest) { bucket in
                Button {
                    state.selectedDate = bucket.id
                    state.hoveredDate = nil
                } label: {
                    HStack {
                        Text(bucket.label).foregroundStyle(.secondary)
                        Spacer()
                        Text(UsageFormat.bytes(bucket.totals.total)).monospacedDigit().fontWeight(.medium)
                        Image(systemName: "chevron.forward").font(.caption2).foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.callout)
                .help("在趋势图查看此时段")
                .accessibilityAddTraits(bucket.id == state.selectedDate ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(UsagePanel(inset: 16))
    }

    private func dataPoint(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func chartScope(_ report: UsageReport) -> UsageBucketScope {
        if let scope = state.scopes.last, let visible = scope.interval.intersection(with: report.period.current), visible.duration > 0 {
            return UsageBucketScope(interval: visible, granularity: scope.granularity)
        }
        return report.rootScope
    }

    private func selectedBucket(in buckets: [UsageBucket]) -> UsageBucket? {
        let selection = state.hoveredDate ?? state.selectedDate
        return buckets.first { $0.id == selection }
            ?? buckets.last { $0.totals.hasRecords } ?? buckets.last
    }

    private func trafficAmount(_ totals: UsageTotals, bytes: Double) -> String {
        totals.samples > 0 ? UsageFormat.bytes(bytes) : "—"
    }

    private func periodLabel(_ period: UsagePeriod) -> String {
        let last = period.current.end.addingTimeInterval(-1)
        if period.range == .day {
            return "\(UsageGranularity.hour.title(for: period.current)) – \(UsageFormat.date(last)) · \(UsageGranularity.hour.axisLabel(last))"
        }
        return "\(UsageFormat.fullDate(period.current.start)) – \(UsageFormat.fullDate(last))"
    }

    private func comparison(_ report: UsageReport) -> String {
        guard report.totals.samples > 0 else { return "本期暂无流量采样" }
        guard report.previous.samples > 0 else { return "上一周期暂无记录" }
        let previous = report.previous.total
        let priorAmount = UsageFormat.bytes(previous)
        guard previous > 0 else { return "上一周期 \(priorAmount)" }
        let change = (report.totals.total - previous) / previous
        let delta = change.formatted(.percent.sign(strategy: .always(includingZero: false)).precision(.fractionLength(0)))
        return "较上一周期 \(delta) · 上期 \(priorAmount)"
    }

    private func load() async {
        let period = UsagePeriod(range: range, now: .now)
        do {
            let entries = try await store.trafficEntries(from: period.previous.start, until: period.current.end)
            guard !Task.isCancelled else { return }
            state.report = UsageReport(period: period, entries: entries)
            state.loadFailed = false
        } catch {
            guard !Task.isCancelled else { return }
            state.loadFailed = true
        }
    }

    private struct LoadRequest: Equatable {
        let range: UsageRange
        let revision: Int
        let retry: Int
    }
}

private enum HistoryDataSource: String, CaseIterable, Identifiable {
    case local, digitalOcean

    var id: Self { self }
    var title: String { self == .local ? "本机" : "DigitalOcean" }
}

@MainActor
private final class UsageHistoryWindowState: ObservableObject {
    @Published var report: UsageReport?
    @Published var loadFailed = false
    @Published var retry = 0
    @Published var scopes: [UsageBucketScope] = []
    @Published var selectedDate: Date?
    @Published var hoveredDate: Date?
}

private struct UsagePanel: ViewModifier {
    let inset: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(inset)
            .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary).allowsHitTesting(false))
    }
}
