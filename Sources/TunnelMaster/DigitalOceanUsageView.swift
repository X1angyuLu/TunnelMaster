import Charts
import SwiftUI
import TunnelMasterCore

@MainActor
struct DigitalOceanUsageView: View {
    @ObservedObject var source: DigitalOceanSource
    @AppStorage("digitalOceanUsageDays") private var range = DigitalOceanUsageRange.day
    @StateObject private var state = DigitalOceanUsageState()

    private static let inboundColor = Color.teal
    private static let outboundColor = Color.purple
    private static let billingURL = URL(string: "https://cloud.digitalocean.com/account/billing")!
    private static let tokensURL = URL(string: "https://cloud.digitalocean.com/account/api/tokens")!

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
                    bandwidthChart(report)
                        .frame(height: 211)
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

    private func bandwidthChart(_ report: DigitalOceanBandwidthReport) -> some View {
        let inbound = Self.chartSamples(report.inbound.samples)
        let outbound = Self.chartSamples(report.outbound.samples)
        let peak = max(report.inbound.peakMbps ?? 0, report.outbound.peakMbps ?? 0)
        return Chart {
            ForEach(inbound) { sample in
                PointMark(x: .value("时间", sample.timestamp), y: .value("入站 Mbps", sample.mbps))
                    .foregroundStyle(Self.inboundColor.opacity(0.8))
                    .symbol(.circle).symbolSize(10)
            }
            ForEach(outbound) { sample in
                PointMark(x: .value("时间", sample.timestamp), y: .value("出站 Mbps", sample.mbps))
                    .foregroundStyle(Self.outboundColor.opacity(0.8))
                    .symbol(.diamond).symbolSize(13)
            }
        }
        .chartXScale(domain: report.from...report.until)
        .chartYScale(domain: 0...max(0.01, peak * 1.08))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisTick().foregroundStyle(.secondary.opacity(0.35))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text((range == .day ? UsageGranularity.hour : .day).axisLabel(date))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                AxisValueLabel {
                    if let speed = value.as(Double.self) {
                        Text(rate(speed))
                    }
                }
            }
        }
        .accessibilityLabel("Droplet 公网入站和出站带宽，单位 Mbps")
    }

    // Retain the range of observed values at a readable density on long charts.
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
            Text("填入这台服务器的 Droplet ID 和具有 monitoring:read 权限的 Token。保存的 Token 存放在这台 Mac 的钥匙串。")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                TextField("Droplet ID", text: $state.dropletID, prompt: Text("数字 ID"))
                    .textFieldStyle(.roundedBorder)
                SecureField("API Token", text: $state.token)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(maxWidth: 430)
            .disabled(state.saving)

            if let error = state.configurationError {
                errorNotice(error)
            }

            HStack(spacing: 12) {
                Button("验证并保存", action: saveCredentials)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                if state.saving {
                    ProgressView().controlSize(.small).accessibilityLabel("正在验证凭据")
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
            Text("这会从本机钥匙串移除保存的 API Token。")
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

    private var canSave: Bool {
        !state.saving && (UInt64(state.dropletID.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
            && !state.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveCredentials() {
        let id = state.dropletID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = state.token.trimmingCharacters(in: .whitespacesAndNewlines)
        state.token = ""
        state.configurationError = nil
        state.saving = true
        Task {
            defer { state.saving = false }
            do {
                try await source.credentials(dropletID: id, token: token)
                range = .day
                closeConfiguration()
            } catch {
                state.configurationError = (error as? LocalizedError)?.errorDescription ?? "无法验证 DigitalOcean 凭据。"
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
    @Published var refresh = 0
    var completedRefresh = 0
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
