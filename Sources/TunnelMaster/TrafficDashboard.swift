import Charts
import SwiftUI

@MainActor
struct TrafficDashboard: View {
    let isConnected: Bool
    let connectedAt: Date?
    let traffic: TrafficSnapshot?
    let history: [TrafficSample]
    @StateObject private var selection = MenuChartSelection()

    var body: some View {
        let samples = isConnected && traffic != nil ? history : []
        let selected = samples.first { $0.id == selection.active } ?? samples.last
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                MenuMetricTile(title: "下载速率", icon: "arrow.down", label: rateLabel(traffic?.downloadRate),
                               detail: sessionTotal(traffic?.downloadTotal), color: isConnected ? .teal : .secondary)
                Divider().frame(height: 43)
                MenuMetricTile(title: "上传速率", icon: "arrow.up", label: rateLabel(traffic?.uploadRate),
                               detail: sessionTotal(traffic?.uploadTotal), color: isConnected ? .purple : .secondary)
            }

            Group {
                if let last = samples.last, samples.count >= 2 {
                    rateChart(samples, last: last, selected: selected)
                } else {
                    Text(chartPlaceholder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
                }
            }
            .frame(height: 77)

            MenuChartInspector(
                timestamp: selected.map { MenuChartSelection.time($0.timestamp, seconds: true) } ?? "—",
                primary: rateLabel(selected?.downloadRate), secondary: rateLabel(selected?.uploadRate),
                primaryLabel: "下载速率", secondaryLabel: "上传速率",
                dates: samples.map(\.id), selected: selected?.id, selection: selection
            )

            Divider()

            HStack(spacing: 8) {
                sessionStat("活跃连接", symbol: "point.3.connected.trianglepath.dotted") {
                    Text(traffic.map { $0.connectionCount.formatted() } ?? "—")
                }
                Spacer(minLength: 4)
                sessionStat("连接时长", symbol: "clock") {
                    if let connectedAt {
                        Text(connectedAt, style: .timer)
                    } else {
                        Text("—")
                    }
                }
            }
            .frame(minHeight: 14)
        }
        .modifier(MenuTrafficFrame())
        .onChange(of: connectedAt) { _ in
            selection.hover(nil)
            selection.clearPin()
        }
        .onChange(of: samples.map(\.id)) { timestamps in
            if let pinned = selection.pinned, !timestamps.contains(pinned) { selection.clearPin() }
        }
        .onDisappear { selection.hover(nil) }
    }

    private func rateChart(_ samples: [TrafficSample], last: TrafficSample, selected: TrafficSample?) -> some View {
        let peak = samples.map { max($0.downloadRate, $0.uploadRate) }.max() ?? 0
        let upperBound = max(1, peak * 1.08)
        let start = last.timestamp.addingTimeInterval(-60)
        return Chart {
            ForEach(samples) { sample in
                LineMark(x: .value("时间", sample.timestamp), y: .value("下载速率", sample.downloadRate), series: .value("方向", "下载"))
                    .foregroundStyle(Color.teal)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

                LineMark(x: .value("时间", sample.timestamp), y: .value("上传速率", sample.uploadRate), series: .value("方向", "上传"))
                    .foregroundStyle(Color.purple)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round, dash: [4, 3]))
            }
            if let selected {
                RuleMark(x: .value("检查时间", selected.timestamp))
                    .foregroundStyle(.secondary.opacity(0.42))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                PointMark(x: .value("时间", selected.timestamp), y: .value("下载速率", selected.downloadRate))
                    .foregroundStyle(Color.teal).symbolSize(17)
                PointMark(x: .value("时间", selected.timestamp), y: .value("上传速率", selected.uploadRate))
                    .foregroundStyle(Color.purple).symbolSize(17)
            }
        }
        .chartXScale(domain: start...last.timestamp)
        .chartYScale(domain: 0...upperBound)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, upperBound / 2, upperBound]) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.16))
            }
        }
        .chartOverlay { proxy in
            MenuChartInteraction(chart: proxy, selection: selection) { date in
                let nearest = samples.min { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }
                guard let nearest, abs(nearest.timestamp.timeIntervalSince(date)) <= 5 else { return nil }
                return nearest.id
            }
        }
        .accessibilityLabel("近 60 秒的上传和下载速率")
        .accessibilityAdjustableAction { direction in
            selection.step(direction, from: selected?.id, across: samples.map(\.id))
        }
    }

    private var chartPlaceholder: String {
        guard isConnected else { return "连接后显示实时趋势" }
        return traffic == nil ? "暂无流量数据" : "正在采样…"
    }

    private func sessionStat<Value: View>(_ title: String, symbol: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 4) {
            Label(title, systemImage: symbol).foregroundStyle(.secondary)
            value().fontWeight(.semibold).monospacedDigit()
        }
        .font(.caption2)
        .accessibilityElement(children: .combine)
    }

    private func sessionTotal(_ bytes: Int64?) -> String {
        "本次 \(bytes.map { UsageFormat.bytes(Double($0)) } ?? "—")"
    }

    private func rateLabel(_ rate: Double?) -> String {
        guard let rate, rate.isFinite, rate >= 0 else { return "—" }
        return UsageFormat.rate(rate)
    }
}
