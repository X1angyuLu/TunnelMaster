import AppKit
import Charts
import SwiftUI

@MainActor
struct MenuChartDetailView: View {
    static let size = CGSize(width: 414, height: 472)

    @ObservedObject private var store: TunnelStore
    @ObservedObject private var server: DigitalOceanSource
    @ObservedObject private var selection: MenuChartDetailSelection
    @StateObject private var controls: MenuChartDetailControls
    @StateObject private var loader = MenuTrafficLoader()
    @StateObject private var chartSelection = MenuChartSelection()
    private let context: MenuChartDetailContext
    private let close: @MainActor () -> Void
    private let onEscape: @MainActor () -> Void

    init(store: TunnelStore, context: MenuChartDetailContext, selection: MenuChartDetailSelection,
         close: @escaping @MainActor () -> Void, onEscape: @escaping @MainActor () -> Void) {
        self.store = store
        _server = ObservedObject(wrappedValue: store.digitalOcean)
        self.context = context
        self.selection = selection
        self.close = close
        self.onEscape = onEscape
        _controls = StateObject(wrappedValue: MenuChartDetailControls(context: context, anchor: selection.selectedDate))
    }

    var body: some View {
        let request = loadRequest
        VStack(alignment: .leading, spacing: 11) {
            header
            scopeControls
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if controls.source == .live {
                        liveContent
                    } else {
                        historyContent
                    }
                }
                .padding(.trailing, 2)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.quaternary).allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .task(id: request) { await load(request) }
        .onChange(of: context) { newContext in
            controls.source = newContext.source
            controls.range = Self.validRange(newContext.range, for: newContext.source)
            anchor(selection.selectedDate)
        }
        .onChange(of: selection.selectedDate) { date in
            if let date, controls.source == context.source { anchor(date) }
        }
        .onExitCommand(perform: onEscape)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("流量详情", systemImage: "chart.xyaxis.line")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if controls.source == .server,
               let id = server.dropletID {
                Text("Droplet \(id)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button(action: close) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭流量详情")
        }
    }

    private var scopeControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                scopeButton("实时", selected: controls.source == .live) { changeSource(.live) }
                scopeButton("本机", selected: controls.source == .local) { changeSource(.local) }
                if server.dropletID != nil || controls.source == .server {
                    scopeButton("服务器", selected: controls.source == .server) { changeSource(.server) }
                }
            }
            .padding(2)
            .background(.quaternary.opacity(0.53), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("流量数据源")

            Spacer(minLength: 2)

            if controls.source == .live {
                Text("最近 60 秒")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 2) {
                    ForEach(Self.ranges(for: controls.source)) { range in
                        scopeButton(range.title, selected: controls.range == range) {
                            controls.range = range
                            clearChartSelection()
                        }
                    }
                }
                .padding(2)
                .background(.quaternary.opacity(0.53), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("历史时段")
                if controls.source == .server {
                    Button { controls.refresh += 1 } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 18, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .disabled(server.dropletID == nil || loader.isLoading)
                    .accessibilityLabel("刷新服务器流量")
                }
            }
        }
        .frame(height: 29)
    }

    private func scopeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(selected ? .semibold : .medium))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 23)
                .background(selected ? Color(nsColor: .controlBackgroundColor) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var liveContent: some View {
        let traffic = store.status == .connected ? store.traffic : nil
        let samples = traffic == nil ? [] : store.trafficHistory
        let preferred = chartSelection.active ?? controls.anchor
        let selected = samples.first { $0.id == preferred } ?? samples.last
        return VStack(alignment: .leading, spacing: 12) {
            directionTotals(
                primary: traffic.map { Double($0.downloadTotal) }, secondary: traffic.map { Double($0.uploadTotal) },
                primaryDetail: "当前 \(rate(traffic?.downloadRate))", secondaryDetail: "当前 \(rate(traffic?.uploadRate))",
                primaryTitle: "本次下载", secondaryTitle: "本次上传"
            )

            if let last = samples.last, samples.count >= 2 {
                liveChart(samples, last: last, selected: selected)
                    .frame(height: 154)
            } else {
                plotPlaceholder(store.status == .connected ? "正在等待流量采样" : "连接后显示实时速率")
            }

            MenuChartInspector(
                timestamp: selected.map { MenuChartSelection.time($0.timestamp, seconds: true) } ?? "—",
                primary: rate(selected?.downloadRate), secondary: rate(selected?.uploadRate),
                primaryLabel: "下载速率", secondaryLabel: "上传速率", dates: samples.map(\.id),
                selected: selected?.id, selection: chartSelection
            )

            HStack(spacing: 7) {
                detailMetric("活跃连接", value: traffic.map { $0.connectionCount.formatted() } ?? "—")
                detailMetric("峰值下载", value: rate(samples.map(\.downloadRate).max()))
                detailMetric("峰值上传", value: rate(samples.map(\.uploadRate).max()))
            }
            Text("仅统计本机由 Mihomo 接管的流量。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var historyContent: some View {
        let isServer = controls.source == .server
        let report = isServer && server.dropletID == nil ? nil : loader.report(
            for: controls.range, serverID: isServer ? server.dropletID : nil,
            monitoringRevision: isServer ? server.monitoringRevision : nil
        )
        let buckets = report?.buckets ?? []
        let preferred = chartSelection.active ?? controls.anchor
        let selected = preferred.flatMap { date in bucket(at: date, in: buckets) }
            ?? buckets.last { Self.hasMeasuredTraffic($0) }
        let granularity: UsageGranularity = controls.range == .day ? .hour : .day
        let primary = isServer ? "公网入站" : "下载总量"
        let secondary = isServer ? "公网出站" : "上传总量"
        return VStack(alignment: .leading, spacing: 12) {
            directionTotals(primary: report?.primaryBytes, secondary: report?.secondaryBytes,
                            primaryDetail: peakLabel(selected?.peakPrimaryRate), secondaryDetail: peakLabel(selected?.peakSecondaryRate),
                            primaryTitle: primary, secondaryTitle: secondary)

            if let report,
               buckets.contains(where: Self.hasMeasuredTraffic) {
                historyChart(report, granularity: granularity, selected: selected, primary: primary, secondary: secondary)
                    .frame(height: 154)
            } else {
                plotPlaceholder(historyPlaceholder(hasReport: report != nil))
            }

            MenuChartInspector(
                timestamp: selected.map { granularity.title(for: $0.interval) } ?? "—",
                primary: bytes(selected?.primaryBytes), secondary: bytes(selected?.secondaryBytes),
                primaryLabel: primary, secondaryLabel: secondary,
                dates: selected == nil ? [] : buckets.map(\.id), selected: selected?.id, selection: chartSelection
            )

            if isServer {
                HStack(spacing: 7) {
                    detailMetric("所选采样覆盖", value: percent(selected?.coverage))
                    detailMetric("此范围覆盖", value: percent(report?.coverage))
                    detailMetric("获取时间", value: report?.updatedAt.map { MenuChartSelection.time($0, seconds: false) } ?? "—")
                }
            } else {
                HStack(spacing: 7) {
                    detailMetric("连接时长", value: selected?.connectedSeconds.map(UsageFormat.duration) ?? "—")
                    detailMetric("发起连接", value: selected?.sessionsStarted.map { $0.formatted() + " 次" } ?? "—")
                    detailMetric("活跃连接峰值", value: selected?.peakConnections.map { $0.formatted() } ?? "—")
                }
            }

            if let error = loader.errorMessage, controls.completed == loadRequest {
                Label(report == nil ? error : "更新失败，显示上次数据。", systemImage: "exclamationmark.circle")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(isServer ? "根据 Droplet 公网采样估算。计费用量请查看 DigitalOcean 账单。" : "记录本机由 Mihomo 处理的流量，包含直连和隧道。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func directionTotals(primary: Double?, secondary: Double?, primaryDetail: String, secondaryDetail: String,
                                 primaryTitle: String, secondaryTitle: String) -> some View {
        HStack(spacing: 12) {
            MenuMetricTile(title: primaryTitle, icon: "arrow.down", label: bytes(primary), detail: primaryDetail, color: .teal)
            Divider().frame(height: 42)
            MenuMetricTile(title: secondaryTitle, icon: "arrow.up", label: bytes(secondary), detail: secondaryDetail, color: .purple)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func detailMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.callout.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }

    private func plotPlaceholder(_ title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar.xaxis").font(.title3).accessibilityHidden(true)
            Text(title).font(.caption)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 154)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
    }

    private func liveChart(_ samples: [TrafficSample], last: TrafficSample, selected: TrafficSample?) -> some View {
        let end = last.timestamp
        let peak = samples.map { max($0.downloadRate, $0.uploadRate) }.max() ?? 0
        return Chart {
            ForEach(samples) { sample in
                LineMark(x: .value("时间", sample.timestamp), y: .value("下载速率", sample.downloadRate), series: .value("方向", "下载"))
                    .foregroundStyle(Color.teal).lineStyle(StrokeStyle(lineWidth: 2))
                LineMark(x: .value("时间", sample.timestamp), y: .value("上传速率", sample.uploadRate), series: .value("方向", "上传"))
                    .foregroundStyle(Color.purple).lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
            if let selected {
                indicator(selected.timestamp)
                PointMark(x: .value("时间", selected.timestamp), y: .value("下载速率", selected.downloadRate))
                    .foregroundStyle(Color.teal).symbolSize(26)
                PointMark(x: .value("时间", selected.timestamp), y: .value("上传速率", selected.uploadRate))
                    .foregroundStyle(Color.purple).symbolSize(26)
            }
        }
        .chartXScale(domain: end.addingTimeInterval(-60)...end)
        .chartYScale(domain: 0...max(1, peak * 1.1))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) { Text(MenuChartSelection.time(date, seconds: true)) }
                }
            }
        }
        .chartYAxis { axisValues(rate) }
        .chartOverlay { chart in
            MenuChartInteraction(chart: chart, selection: chartSelection) { date in
                let nearest = samples.min { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }
                guard let nearest, abs(nearest.timestamp.timeIntervalSince(date)) <= 5 else { return nil }
                return nearest.id
            }
        }
        .accessibilityLabel("上传与下载实时速率")
        .accessibilityAdjustableAction { direction in
            chartSelection.step(direction, from: selected?.id, across: samples.map(\.id))
        }
    }

    private func historyChart(_ report: MenuTrafficReport, granularity: UsageGranularity, selected: MenuTrafficBucket?,
                              primary: String, secondary: String) -> some View {
        let peak = report.buckets.map { ($0.primaryBytes ?? 0) + ($0.secondaryBytes ?? 0) }.max() ?? 0
        return Chart {
            ForEach(report.buckets) { bucket in
                bucketMarks(bucket, selected: bucket.id == selected?.id, primary: primary, secondary: secondary)
            }
            if let selected { indicator(selected.interval.start.addingTimeInterval(selected.interval.duration / 2)) }
        }
        .chartXScale(domain: report.interval.start...report.interval.end)
        .chartYScale(domain: 0...max(1, peak * 1.1))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) { Text(granularity.axisLabel(date)) }
                }
            }
        }
        .chartYAxis { axisValues(bytes) }
        .chartOverlay { chart in
            MenuChartInteraction(chart: chart, selection: chartSelection) { date in
                bucket(at: date, in: report.buckets)?.id
            }
        }
        .accessibilityLabel("\(primary)与\(secondary)趋势")
        .accessibilityAdjustableAction { direction in
            chartSelection.step(direction, from: selected?.id, across: report.buckets.map(\.id))
        }
    }

    private func axisValues(_ format: @escaping (Double?) -> String) -> some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
            AxisGridLine().foregroundStyle(.secondary.opacity(0.17))
            AxisValueLabel { Text(format(value.as(Double.self))) }
        }
    }

    private func indicator(_ date: Date) -> some ChartContent {
        RuleMark(x: .value("选中时段", date))
            .foregroundStyle(.secondary.opacity(0.55))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }

    @ChartContentBuilder
    private func bucketMarks(_ bucket: MenuTrafficBucket, selected: Bool, primary: String, secondary: String) -> some ChartContent {
        let margin = bucket.interval.duration * 0.14
        let from = bucket.interval.start.addingTimeInterval(margin)
        let until = bucket.interval.end.addingTimeInterval(-margin)
        let base = bucket.primaryBytes ?? 0
        let opacity = selected ? 1.0 : 0.74
        if base > 0 {
            RectangleMark(xStart: .value("开始", from), xEnd: .value("结束", until),
                          yStart: .value("流量", 0.0), yEnd: .value(primary, base))
                .foregroundStyle(Color.teal.opacity(opacity))
        }
        if let bytes = bucket.secondaryBytes, bytes > 0 {
            RectangleMark(xStart: .value("开始", from), xEnd: .value("结束", until),
                          yStart: .value("流量", base), yEnd: .value(secondary, base + bytes))
                .foregroundStyle(Color.purple.opacity(opacity))
        }
        if Self.hasMeasuredTraffic(bucket), base + (bucket.secondaryBytes ?? 0) == 0 {
            let center = bucket.interval.start.addingTimeInterval(bucket.interval.duration / 2)
            PointMark(x: .value("时间", center), y: .value("流量", 0.0))
                .foregroundStyle(.secondary).symbolSize(10)
        }
    }

    private var loadRequest: MenuChartDetailRequest {
        let isServer = controls.source == .server
        let revision = switch controls.source {
        case .live: 0
        case .local: store.historyRevision
        case .server: server.monitoringRevision
        }
        return MenuChartDetailRequest(source: controls.source, range: controls.range,
                                      serverID: isServer ? server.dropletID : nil,
                                      revision: revision,
                                      refresh: isServer ? controls.refresh : 0)
    }

    private func load(_ request: MenuChartDetailRequest) async {
        switch request.source {
        case .live: return
        case .local:
            await loader.loadLocal(store: store, range: request.range)
        case .server:
            guard request.serverID != nil else { return }
            let force = request.refresh != controls.completedRefresh
            await loader.loadServer(source: server, range: request.range, force: force)
            if !Task.isCancelled { controls.completedRefresh = request.refresh }
        }
        if !Task.isCancelled { controls.completed = request }
    }

    private func historyPlaceholder(hasReport: Bool) -> String {
        if controls.source == .server && server.dropletID == nil { return "尚未配置服务器监控" }
        if loader.isLoading || (controls.completed != loadRequest && !hasReport) { return "正在读取流量记录…" }
        if loader.errorMessage != nil { return "暂时无法读取流量" }
        return "此时段暂无采样"
    }

    private func changeSource(_ source: MenuChartDetailSource) {
        guard controls.source != source else { return }
        controls.source = source
        controls.range = Self.validRange(controls.range, for: source)
        anchor(source == context.source ? selection.selectedDate : nil)
    }

    private func anchor(_ date: Date?) {
        controls.anchor = date
        clearChartSelection()
    }

    private func clearChartSelection() {
        chartSelection.hover(nil)
        chartSelection.clearPin()
    }

    private func bucket(at date: Date, in buckets: [MenuTrafficBucket]) -> MenuTrafficBucket? {
        buckets.first { date >= $0.interval.start && date < $0.interval.end }
    }

    private static func hasMeasuredTraffic(_ bucket: MenuTrafficBucket) -> Bool {
        bucket.primaryBytes != nil || bucket.secondaryBytes != nil
    }

    private static func ranges(for source: MenuChartDetailSource) -> [MenuTrafficRange] {
        switch source {
        case .live: [.day]
        case .local: [.day, .week, .month]
        case .server: [.day, .week, .fortnight]
        }
    }

    fileprivate static func validRange(_ range: MenuTrafficRange, for source: MenuChartDetailSource) -> MenuTrafficRange {
        ranges(for: source).contains(range) ? range : .day
    }

    private func bytes(_ value: Double?) -> String { value.map(UsageFormat.bytes) ?? "—" }
    private func rate(_ value: Double?) -> String { value.map(UsageFormat.rate) ?? "—" }
    private func peakLabel(_ value: Double?) -> String { "所选时段峰值 \(rate(value))" }
    private func percent(_ value: Double?) -> String { value?.formatted(.percent.precision(.fractionLength(0))) ?? "—" }
}

private struct MenuChartDetailRequest: Equatable {
    let source: MenuChartDetailSource
    let range: MenuTrafficRange
    let serverID: String?
    let revision: Int
    let refresh: Int
}

@MainActor
private final class MenuChartDetailControls: ObservableObject {
    @Published var source: MenuChartDetailSource
    @Published var range: MenuTrafficRange
    @Published var anchor: Date?
    @Published var refresh = 0
    @Published var completed: MenuChartDetailRequest?
    var completedRefresh = 0

    init(context: MenuChartDetailContext, anchor: Date?) {
        source = context.source
        range = MenuChartDetailView.validRange(context.range, for: context.source)
        self.anchor = anchor
    }
}
