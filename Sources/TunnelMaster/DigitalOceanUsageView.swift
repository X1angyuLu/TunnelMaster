import Charts
import SwiftUI
import TunnelMasterCore

@MainActor
struct DigitalOceanUsageView: View {
    @ObservedObject var source: DigitalOceanSource
    @AppStorage("digitalOceanUsageDays") private var range = DigitalOceanUsageRange.day
    @StateObject private var state: DigitalOceanUsageState

    private static let inboundColor = Color.teal
    private static let outboundColor = Color.purple
    private static let billingURL = URL(string: "https://cloud.digitalocean.com/account/billing")!
    private static let tokensURL = URL(string: "https://cloud.digitalocean.com/account/api/tokens")!

    init(source: DigitalOceanSource) {
        self.source = source
        _state = StateObject(wrappedValue: DigitalOceanUsageState(storage: source.credentialStorage))
    }

    private var report: DigitalOceanBandwidthReport? {
        guard let report = source.report,
              abs(report.until.timeIntervalSince(report.from) - Double(range.rawValue) * 86_400) < 900 else { return nil }
        return report
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if source.dropletID == nil || state.isEditing {
                    configuration
                } else if let id = source.dropletID {
                    toolbar(id: id)
                    if let message = source.errorMessage {
                        errorNotice(message)
                    }
                    if let report {
                        dashboard(report)
                    } else if source.isLoading || source.errorMessage == nil {
                        ProgressView("正在读取 DigitalOcean 监控数据…")
                            .frame(maxWidth: .infinity, minHeight: 210)
                    }
                }
                billing
            }
            .padding(22)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .task(id: UsageRequest(dropletID: source.dropletID, range: range, refresh: state.refresh)) {
            guard source.dropletID != nil else { return }
            if state.refresh == state.completedRefresh, report != nil,
               let lastUpdated = source.lastUpdated, lastUpdated.timeIntervalSinceNow > -60 { return }
            state.completedRefresh = state.refresh
            await source.load(days: range.rawValue)
        }
    }

    private func toolbar(id: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Droplet \(id)", systemImage: "server.rack")
                    .font(.title3.weight(.semibold))
                Text("汇总共用这台服务器的设备，以及服务器上的其他公网流量。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Picker("监控时段", selection: $range) {
                ForEach(DigitalOceanUsageRange.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 178)

            Button {
                state.refresh += 1
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(source.isLoading)

            Button {
                state.dropletID = id
                state.credentialStorage = source.credentialStorage
                state.configurationError = nil
                state.isEditing = true
            } label: {
                Label("设置", systemImage: "gearshape")
            }
        }
    }

    private func dashboard(_ report: DigitalOceanBandwidthReport) -> some View {
        let duration = report.until.timeIntervalSince(report.from)
        let latest = [report.inbound.samples.last?.timestamp, report.outbound.samples.last?.timestamp]
            .compactMap { $0 }.max()
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                directionCard("公网入站估算", symbol: "arrow.down.left", color: Self.inboundColor,
                              series: report.inbound, duration: duration)
                directionCard("公网出站估算", symbol: "arrow.up.right", color: Self.outboundColor,
                              series: report.outbound, duration: duration)
            }

            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 12) {
                    Text("公网带宽").font(.headline).accessibilityAddTraits(.isHeader)
                    Text("Mbps").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    legend("入站", color: Self.inboundColor, symbol: "circle.fill")
                    legend("出站", color: Self.outboundColor, symbol: "diamond.fill")
                }
                if latest != nil {
                    DigitalOceanBandwidthChart(
                        report: report, axisGranularity: range == .day ? .hour : .day,
                        inboundColor: Self.inboundColor, outboundColor: Self.outboundColor
                    )
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "chart.xyaxis.line").font(.title2).accessibilityHidden(true)
                        Text("此时间段暂无监控采样").font(.callout)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 175)
                }
                HStack(spacing: 12) {
                    if let latest {
                        Text("最近采样 \(timestamp(latest))")
                    }
                    Spacer()
                    if source.isLoading {
                        ProgressView().controlSize(.small).accessibilityLabel("正在更新监控数据")
                    } else if let updated = source.lastUpdated {
                        Text("获取于 \(timestamp(updated))")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(DigitalOceanPanel())
        }
    }

    private func directionCard(_ title: String, symbol: String, color: Color,
                               series: DigitalOceanBandwidthSeries, duration: TimeInterval) -> some View {
        let coverage = duration > 0 ? min(1, max(0, series.coveredSeconds / duration)) : 0
        return VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol).font(.callout.weight(.semibold)).foregroundStyle(color)
            Text(series.estimatedBytes.map { UsageFormat.bytes(Double($0)) } ?? "—")
                .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            ProgressView(value: coverage).tint(color)
                .accessibilityLabel("可用于估算的时段")
            HStack {
                Text("采样覆盖 \(coverage.formatted(.percent.precision(.fractionLength(0))))")
                Spacer()
                Text(series.peakMbps.map { "峰值 \(rate($0)) Mbps" } ?? "暂无峰值")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(DigitalOceanPanel())
    }

    private func legend(_ title: String, color: Color, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(color)
    }

    private var billing: some View {
        HStack(alignment: .center, spacing: 15) {
            VStack(alignment: .leading, spacing: 5) {
                Text("账单流量与套餐额度").font(.callout.weight(.semibold))
                Text("监控估算按已采样时段计算。实际计费流量和团队共享额度请查看 DigitalOcean 账单。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Link(destination: Self.billingURL) {
                Label("打开账单", systemImage: "arrow.up.right")
            }
        }
        .modifier(DigitalOceanPanel(inset: 13))
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(state.isEditing ? "DigitalOcean 设置" : "连接 DigitalOcean 监控", systemImage: "server.rack")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("填入这台服务器的 Droplet ID 和具有 monitoring:read 权限的 Token。")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                TextField("Droplet ID", text: $state.dropletID, prompt: Text("数字 ID"))
                    .textFieldStyle(.roundedBorder)
                SecureField("API Token", text: $state.token)
                    .textFieldStyle(.roundedBorder)
                Picker("Token 存储位置", selection: $state.credentialStorage) {
                    ForEach(DigitalOceanCredentialStorage.allCases) { storage in
                        Text(storage.title).tag(storage)
                    }
                }
                .pickerStyle(.segmented)
                Text(storageDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 430)
            .disabled(state.saving)

            if let error = state.configurationError {
                errorNotice(error)
            }

            HStack(spacing: 12) {
                Button(canMigrateToLocalFile ? "保存到本机文件" : "验证并保存", action: saveCredentials)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                if state.saving {
                    ProgressView().controlSize(.small).accessibilityLabel("正在保存凭据")
                }
                if state.isEditing {
                    Button("取消", action: closeConfiguration)
                        .disabled(state.saving)
                }
                Link(destination: Self.tokensURL) {
                    Label("管理 API Token", systemImage: "arrow.up.right")
                }
                Spacer()
                if source.dropletID != nil {
                    Button("移除此数据源", role: .destructive) { state.confirmRemoval = true }
                        .disabled(state.saving)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .leading)
        .modifier(DigitalOceanPanel())
        .confirmationDialog("移除 DigitalOcean 数据源？", isPresented: $state.confirmRemoval, titleVisibility: .visible) {
            Button("移除", role: .destructive, action: removeCredentials)
        } message: {
            Text(source.credentialStorage == .localFile
                 ? "这会删除本机令牌文件和数据源配置。"
                 : "这会从钥匙串移除令牌，并删除数据源配置。")
        }
    }

    private func errorNotice(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var dropletIDDraft: String { state.dropletID.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tokenDraft: String { state.token.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canMigrateToLocalFile: Bool {
        state.credentialStorage == .localFile && source.credentialStorage == .keychain
            && source.dropletID == dropletIDDraft && tokenDraft.isEmpty
    }

    private var storageDescription: String {
        switch state.credentialStorage {
        case .keychain:
            "Token 保存在这台 Mac 的钥匙串。"
        case .localFile:
            if canMigrateToLocalFile {
                "可复制钥匙串里的现有 Token，macOS 可能会要求授权读取。应用将改用本机文件中的明文 Token，同一 macOS 用户运行的程序也可读取。"
            } else {
                "Token 以明文保存在本机应用数据目录。以当前 macOS 用户身份运行的程序可读取。"
            }
        }
    }

    private var canSave: Bool {
        !state.saving && (UInt64(dropletIDDraft) ?? 0) > 0 && (canMigrateToLocalFile || !tokenDraft.isEmpty)
    }

    private func saveCredentials() {
        let id = dropletIDDraft
        let token = tokenDraft
        let storage = state.credentialStorage
        let migrating = canMigrateToLocalFile
        state.token = ""
        state.configurationError = nil
        state.saving = true
        Task {
            defer { state.saving = false }
            do {
                if migrating {
                    try source.saveCredentialLocally()
                    state.refresh += 1
                } else {
                    try await source.credentials(dropletID: id, token: token, storage: storage)
                    range = .day
                }
                closeConfiguration()
            } catch {
                state.configurationError = (error as? LocalizedError)?.errorDescription
                    ?? (migrating ? "无法将 DigitalOcean 凭据迁移到本机文件。" : "无法验证 DigitalOcean 凭据。")
            }
        }
    }

    private func removeCredentials() {
        do {
            try source.removeCredentials()
            state.dropletID = ""
            closeConfiguration()
        } catch {
            state.configurationError = (error as? LocalizedError)?.errorDescription ?? "无法移除本机凭据。"
        }
    }

    private func closeConfiguration() {
        state.token = ""
        state.credentialStorage = source.credentialStorage
        state.configurationError = nil
        state.isEditing = false
    }

    private func rate(_ mbps: Double) -> String { mbps.formatted(.number.precision(.fractionLength(0...3))) }

    private func timestamp(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day()
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(UsageFormat.locale))
    }

    private struct UsageRequest: Equatable {
        let dropletID: String?
        let range: DigitalOceanUsageRange
        let refresh: Int
    }
}

@MainActor
private struct DigitalOceanBandwidthChart: View {
    let report: DigitalOceanBandwidthReport
    let axisGranularity: UsageGranularity
    let inboundColor: Color
    let outboundColor: Color

    @StateObject private var inspection = Inspection()

    private let samples: DigitalOceanChartSamples
    private let inboundMarks: [DigitalOceanBandwidthSample]
    private let outboundMarks: [DigitalOceanBandwidthSample]

    init(report: DigitalOceanBandwidthReport, axisGranularity: UsageGranularity, inboundColor: Color, outboundColor: Color) {
        self.report = report
        self.axisGranularity = axisGranularity
        self.inboundColor = inboundColor
        self.outboundColor = outboundColor
        samples = DigitalOceanChartSamples(inbound: report.inbound.samples, outbound: report.outbound.samples)
        inboundMarks = Self.chartSamples(report.inbound.samples)
        outboundMarks = Self.chartSamples(report.outbound.samples)
    }

    private enum Hover: Equatable {
        case sample(Date)
        case gap
    }

    @MainActor
    private final class Inspection: ObservableObject {
        @Published var hover: Hover?
        @Published var pinnedDate: Date?
    }

    private var selectedDate: Date? {
        switch inspection.hover {
        case .sample(let date): return date
        case .gap: return nil
        case nil:
            guard let pinnedDate = inspection.pinnedDate, samples.contains(pinnedDate) else { return nil }
            return pinnedDate
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            chart
                .frame(height: 211)
            inspector
        }
        .onChange(of: report.until) { _ in
            inspection.hover = nil
            if let pinnedDate = inspection.pinnedDate, !samples.contains(pinnedDate) { inspection.pinnedDate = nil }
        }
    }

    private var chart: some View {
        let peak = max(report.inbound.peakMbps ?? 0, report.outbound.peakMbps ?? 0)
        return Chart {
            ForEach(inboundMarks) { sample in
                PointMark(x: .value("时间", sample.timestamp), y: .value("入站 Mbps", sample.mbps))
                    .foregroundStyle(inboundColor.opacity(0.8))
                    .symbol(.circle).symbolSize(10)
            }
            ForEach(outboundMarks) { sample in
                PointMark(x: .value("时间", sample.timestamp), y: .value("出站 Mbps", sample.mbps))
                    .foregroundStyle(outboundColor.opacity(0.8))
                    .symbol(.diamond).symbolSize(13)
            }
            if let date = selectedDate {
                RuleMark(x: .value("选中采样", date))
                    .foregroundStyle(.secondary.opacity(0.65))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                if let inbound = samples.inbound[date] {
                    PointMark(x: .value("时间", date), y: .value("入站 Mbps", inbound))
                        .foregroundStyle(inboundColor)
                        .symbol(.circle).symbolSize(48)
                }
                if let outbound = samples.outbound[date] {
                    PointMark(x: .value("时间", date), y: .value("出站 Mbps", outbound))
                        .foregroundStyle(outboundColor)
                        .symbol(.diamond).symbolSize(54)
                }
            }
        }
        .chartXScale(domain: report.from...report.until)
        .chartYScale(domain: 0...max(0.01, peak * 1.08))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisTick().foregroundStyle(.secondary.opacity(0.35))
                AxisValueLabel {
                    if let date = value.as(Date.self) { Text(axisGranularity.axisLabel(date)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                AxisValueLabel {
                    if let speed = value.as(Double.self) {
                        Text(speed.formatted(.number.precision(.fractionLength(0...3))))
                    }
                }
            }
        }
        .chartOverlay { proxy in selectionOverlay(proxy) }
        .focusable()
        .onMoveCommand { move in
            switch move {
            case .left: browse(-1)
            case .right: browse(1)
            default: break
            }
        }
        .onExitCommand {
            inspection.hover = nil
            inspection.pinnedDate = nil
        }
        .accessibilityLabel("Droplet 公网入站和出站带宽，单位 Mbps")
        .accessibilityValue(accessibleSelection)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .decrement: browse(-1)
            case .increment: browse(1)
            @unknown default: break
            }
        }
    }

    private func selectionOverlay(_ proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            let plot = geometry[proxy.plotAreaFrame]
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    let next: Hover?
                    if case .active(let point) = phase, let date = date(at: point, plot: plot, proxy: proxy) {
                        next = samples.nearest(to: date).map(Hover.sample) ?? .gap
                    } else {
                        next = nil
                    }
                    if next != inspection.hover { inspection.hover = next }
                }
                .gesture(SpatialTapGesture().onEnded { value in
                    guard let target = date(at: value.location, plot: plot, proxy: proxy) else { return }
                    let sample = samples.nearest(to: target)
                    inspection.pinnedDate = inspection.pinnedDate == sample ? nil : sample
                })
                .accessibilityHidden(true)
        }
    }

    private func date(at point: CGPoint, plot: CGRect, proxy: ChartProxy) -> Date? {
        guard plot.contains(point) else { return nil }
        return proxy.value(atX: point.x - plot.minX)
    }

    private var inspector: some View {
        HStack(spacing: 11) {
            VStack(alignment: .leading, spacing: 3) {
                Text("采样时间").foregroundStyle(.secondary)
                Text(selectionTitle).fontWeight(.medium).lineLimit(1)
            }
            .frame(minWidth: 145, alignment: .leading)
            reading("入站", date: selectedDate, series: samples.inbound, color: inboundColor)
            reading("出站", date: selectedDate, series: samples.outbound, color: outboundColor)

            Button { browse(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(!canBrowse(-1))
                .help("上一条采样")
                .accessibilityLabel("上一条采样")
            Button { browse(1) } label: { Image(systemName: "chevron.right") }
                .disabled(!canBrowse(1))
                .help("下一条采样")
                .accessibilityLabel("下一条采样")
        }
        .font(.caption.monospacedDigit())
        .controlSize(.small)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .frame(minHeight: 42)
        .background(.quaternary.opacity(0.48), in: RoundedRectangle(cornerRadius: 7))
    }

    private func reading(_ title: String, date: Date?, series: [Date: Double], color: Color) -> some View {
        let value = rateText(date.flatMap { series[$0] })
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).foregroundStyle(color)
            Text(value ?? "—").lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value ?? "无采样")
    }

    private var selectionTitle: String {
        guard let selectedDate else { return inspection.hover == .gap ? "此处附近无采样" : "悬停或选取采样点" }
        return selectedDate.formatted(.dateTime.year().month().day()
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).locale(UsageFormat.locale))
    }

    private var accessibleSelection: String {
        guard let selectedDate else { return selectionTitle }
        let inbound = rateText(samples.inbound[selectedDate]) ?? "无采样"
        let outbound = rateText(samples.outbound[selectedDate]) ?? "无采样"
        return "\(selectionTitle)，入站 \(inbound)，出站 \(outbound)"
    }

    private func rateText(_ mbps: Double?) -> String? {
        mbps.map { "\($0.formatted(.number.precision(.significantDigits(1...8)))) Mbps" }
    }

    private func canBrowse(_ offset: Int) -> Bool {
        samples.adjacent(to: selectedDate ?? inspection.pinnedDate, offset: offset) != nil
    }

    private func browse(_ offset: Int) {
        guard let next = samples.adjacent(to: selectedDate ?? inspection.pinnedDate, offset: offset) else { return }
        inspection.pinnedDate = next
        inspection.hover = nil
    }

    // Retain plotted extremes on long ranges. Hit testing always uses the full samples instead.
    private static func chartSamples(_ samples: [DigitalOceanBandwidthSample]) -> [DigitalOceanBandwidthSample] {
        guard samples.count > 1_000 else { return samples }
        let strideSize = (samples.count + 499) / 500
        return stride(from: 0, to: samples.count, by: strideSize).flatMap { start -> [DigitalOceanBandwidthSample] in
            let group = samples[start..<min(start + strideSize, samples.count)]
            guard let low = group.min(by: { $0.mbps < $1.mbps }),
                  let high = group.max(by: { $0.mbps < $1.mbps }) else { return [] }
            return low.id == high.id ? [low] : [low, high]
        }
    }
}

private struct DigitalOceanChartSamples {
    let inbound: [Date: Double]
    let outbound: [Date: Double]
    private let dates: [Date]
    private let tolerance: TimeInterval

    init(inbound: [DigitalOceanBandwidthSample], outbound: [DigitalOceanBandwidthSample]) {
        self.inbound = Dictionary(uniqueKeysWithValues: inbound.map { ($0.timestamp, $0.mbps) })
        self.outbound = Dictionary(uniqueKeysWithValues: outbound.map { ($0.timestamp, $0.mbps) })
        dates = Set(self.inbound.keys).union(self.outbound.keys).sorted()
        // Infer cadence within a direction so a small timestamp skew between directions has no effect.
        let distinctCadences = [Self.cadence(inbound), Self.cadence(outbound)].compactMap { $0 }
        tolerance = min(15 * 60, (distinctCadences.min() ?? 60) / 2)
    }

    func contains(_ date: Date) -> Bool {
        inbound[date] != nil || outbound[date] != nil
    }

    func nearest(to date: Date) -> Date? {
        let index = insertionIndex(for: date)
        let candidate = [index - 1, index].compactMap { dates.indices.contains($0) ? dates[$0] : nil }.min {
            abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date))
        }
        guard let candidate, abs(candidate.timeIntervalSince(date)) <= tolerance else { return nil }
        return candidate
    }

    func adjacent(to date: Date?, offset: Int) -> Date? {
        guard let date, contains(date) else { return offset < 0 ? dates.last : dates.first }
        let next = insertionIndex(for: date) + offset
        return dates.indices.contains(next) ? dates[next] : nil
    }

    private func insertionIndex(for date: Date) -> Int {
        var lowerBound = 0
        var upperBound = dates.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if dates[middle] < date { lowerBound = middle + 1 }
            else { upperBound = middle }
        }
        return lowerBound
    }

    private static func cadence(_ samples: [DigitalOceanBandwidthSample]) -> TimeInterval? {
        let intervals = zip(samples, samples.dropFirst()).map { $1.timestamp.timeIntervalSince($0.timestamp) }
            .filter { $0 > 0 }.sorted()
        guard !intervals.isEmpty else { return nil }
        return intervals[(intervals.count - 1) / 2]
    }
}

private enum DigitalOceanUsageRange: Int, CaseIterable, Identifiable {
    case day = 1, week = 7, fortnight = 14
    var id: Self { self }
    var title: String { self == .day ? "24 小时" : "\(rawValue) 天" }
}

@MainActor
private final class DigitalOceanUsageState: ObservableObject {
    @Published var isEditing = false
    @Published var saving = false
    @Published var confirmRemoval = false
    @Published var configurationError: String?
    @Published var dropletID = ""
    @Published var token = ""
    @Published var credentialStorage: DigitalOceanCredentialStorage
    @Published var refresh = 0
    var completedRefresh = 0

    init(storage: DigitalOceanCredentialStorage) {
        credentialStorage = storage
    }
}

private struct DigitalOceanPanel: ViewModifier {
    var inset: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(inset)
            .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary).allowsHitTesting(false))
    }
}
