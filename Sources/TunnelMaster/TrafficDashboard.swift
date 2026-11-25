import Charts
import SwiftUI

struct TrafficDashboard: View {
    let isConnected: Bool
    let connectedAt: Date?
    let traffic: TrafficSnapshot?
    let history: [TrafficSample]

    private static let historyWindow: TimeInterval = 60
    private static let downloadColor: Color = .teal
    private static let uploadColor: Color = .purple

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("实时流量")
                    .font(.callout.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("近 60 秒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                transfer(
                    "下载", arrow: "arrow.down", color: Self.downloadColor,
                    rate: traffic?.downloadRate, total: traffic?.downloadTotal
                )
                Divider().frame(height: 49)
                transfer(
                    "上传", arrow: "arrow.up", color: Self.uploadColor,
                    rate: traffic?.uploadRate, total: traffic?.uploadTotal
                )
            }

            rateChart
                .frame(height: 54)

            Divider()

            HStack(spacing: 10) {
                sessionStat("活跃连接", symbol: "point.3.connected.trianglepath.dotted") {
                    Text(traffic.map { $0.connectionCount.formatted() } ?? "—")
                }
                Spacer(minLength: 6)
                sessionStat("连接时长", symbol: "clock") {
                    if let connectedAt {
                        Text(connectedAt, style: .timer)
                    } else {
                        Text("—")
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.quaternary))
        .help("统计包含 Mihomo 处理的直连与隧道流量，从本次连接开始累计。")
    }

    private func transfer(_ title: String, arrow: String, color: Color, rate: Double?, total: Int64?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: arrow)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isConnected ? color : .secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(Self.rateLabel(rate))
                .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text("累计 \(total.map(Self.byteLabel) ?? "—")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var rateChart: some View {
        if isConnected, traffic != nil, let last = history.last, history.count >= 2 {
            let peak = history.map { max($0.downloadRate, $0.uploadRate) }.max() ?? 0
            let upperBound = max(1, peak * 1.08)
            let start = last.timestamp.addingTimeInterval(-Self.historyWindow)
            Chart {
                ForEach(history) { sample in
                    LineMark(
                        x: .value("时间", sample.timestamp),
                        y: .value("下载速率", sample.downloadRate),
                        series: .value("方向", "下载")
                    )
                    .foregroundStyle(Self.downloadColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round))

                    LineMark(
                        x: .value("时间", sample.timestamp),
                        y: .value("上传速率", sample.uploadRate),
                        series: .value("方向", "上传")
                    )
                    .foregroundStyle(Self.uploadColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round, dash: [4, 3]))
                }
            }
            .chartXScale(domain: start...last.timestamp)
            .chartYScale(domain: 0...upperBound)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, upperBound / 2, upperBound]) {
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                }
            }
            .accessibilityLabel("近 60 秒的上传和下载速率")
        } else {
            Text(chartPlaceholder)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var chartPlaceholder: String {
        guard isConnected else { return "连接后显示流量趋势" }
        return traffic == nil ? "暂无流量数据" : "正在采样…"
    }

    private func sessionStat<Value: View>(_ title: String, symbol: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 5) {
            Label(title, systemImage: symbol)
                .foregroundStyle(.secondary)
            value()
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    private static func byteLabel(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file, spellsOutZero: false))
    }

    private static func rateLabel(_ rate: Double?) -> String {
        guard let rate, rate.isFinite, rate >= 0 else { return "—" }
        let bytes = Int64(exactly: rate.rounded()) ?? Int64.max
        return "\(byteLabel(bytes))/s"
    }
}
