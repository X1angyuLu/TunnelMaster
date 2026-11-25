import AppKit
import SwiftUI

@MainActor
struct MenuView: View {
    @ObservedObject var store: TunnelStore
    @ObservedObject private var serverSource: DigitalOceanSource
    @AppStorage("menuTrafficTab") private var selectedTab = MenuMetricsTab.live
    @AppStorage("menuTrafficRange") private var selectedRange = MenuTrafficRange.day
    @StateObject private var editor = RuleEditorState()
    @StateObject private var metricsView = MenuMetricsState()
    @StateObject private var menuStats = MenuTrafficLoader()
    private let openHistory: @MainActor () -> Void
    private let detailController: MenuChartDetailController
    private let openChartDetail: @MainActor (MenuChartDetailContext) -> Void

    init(
        store: TunnelStore,
        openHistory: @escaping @MainActor () -> Void,
        detailController: MenuChartDetailController,
        openChartDetail: @escaping @MainActor (MenuChartDetailContext) -> Void
    ) {
        self.store = store
        _serverSource = ObservedObject(wrappedValue: store.digitalOcean)
        self.openHistory = openHistory
        self.detailController = detailController
        self.openChartDetail = openChartDetail
    }

    var body: some View {
        Group {
            if editor.isEditing {
                rulesEditor
            } else {
                overview
            }
        }
        .padding(15)
        .frame(width: 394)
        .onAppear { store.refresh() }
    }

    private var overview: some View {
        let request = metricsRequest
        return VStack(alignment: .leading, spacing: 10) {
            header
            connectionCard
            metricsToolbar
            metricsCard
                .environment(\.menuChartDetailController, detailController)
                .environment(\.menuChartDetailContext, detailContext)
            modePicker

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("适用于遵循系统代理的应用")
                    Spacer(minLength: 0)
                    if isRulesMode && store.useChinaIPRules {
                        Label("大陆 IP 直连", systemImage: "checkmark.circle")
                            .accessibilityLabel("中国大陆 IP 直连已开启")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if store.needsProxyRecovery {
                    notice("之前的代理会话已停止。请先恢复系统代理。", symbol: "arrow.uturn.backward", color: .orange)
                } else if store.changedNetwork {
                    notice("网络已切换，请断开后重新连接。", symbol: "wifi.exclamationmark", color: .orange)
                } else if isDisconnected {
                    if store.observedFullTunnel {
                        notice("请先断开当前 macOS VPN。", symbol: "info.circle")
                    } else if !store.hasRuleEngine {
                        notice("安装 Mihomo 后即可使用代理。", symbol: "info.circle")
                    } else if store.profileName == nil {
                        notice("请先导入 WireGuard 配置。", symbol: "info.circle")
                    }
                }
            }

            if let error = store.errorMessage {
                notice(error, symbol: "exclamationmark.circle", color: .orange)
            }

            Button(action: store.toggle) {
                HStack(spacing: 7) {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(store.needsProxyRecovery && isDisconnected ? "恢复系统代理" : actionTitle)
                }
                .font(.system(.body, weight: .semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isBusy || (isDisconnected && connectionUnavailable && !store.needsProxyRecovery))

            Divider()
            footer
        }
        .onAppear { store.setMetricsVisible(activeTab == .live) }
        .onChange(of: activeTab) { store.setMetricsVisible($0 == .live) }
        .onChange(of: detailContext) { _ in detailController.dismiss() }
        .onDisappear {
            store.setMetricsVisible(false)
            detailController.dismiss()
        }
        .task(id: request) { await loadMetrics(request) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe.asia.australia")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isConnected ? Color.teal : Color.secondary)
                .frame(width: 34, height: 34)
                .background((isConnected ? Color.teal : Color.secondary).opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)

            Text("TunnelMaster")
                .font(.system(size: 16, weight: .semibold, design: .rounded))

            Spacer(minLength: 6)

            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(statusTitle)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    private var connectionCard: some View {
        HStack(spacing: 11) {
            VStack(alignment: .leading, spacing: 4) {
                Label("节点", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(store.profileName ?? "尚未选择")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Divider().frame(height: 27)

            HStack(alignment: .center, spacing: 5) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("出口 IP", systemImage: "globe.americas")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(store.exitIP ?? "—")
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)

                Button(action: store.checkExit) {
                    if store.checkingExit {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 16, height: 16)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(!isConnected || store.checkingExit)
                .help("检测当前出口 IP")
                .accessibilityLabel("检测当前出口 IP")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 49)
        .font(.callout)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private var metricsToolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(availableTabs) { tab in
                    statsButton(tab.title, icon: tab.icon, selected: activeTab == tab) { selectedTab = tab }
                }
            }
            .padding(2)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("流量视图")

            Spacer(minLength: 0)

            if activeTab == .live {
                Text("最近 60 秒")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 2)
            } else {
                HStack(spacing: 1) {
                    ForEach([MenuTrafficRange.day, .week]) { range in
                        statsButton(range.title, selected: selectedRange == range) { selectedRange = range }
                    }
                }
                .padding(2)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("统计时间范围")

                if activeTab == .server {
                    Button {
                        metricsView.refresh += 1
                    } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 18, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
                    .disabled(menuStats.isLoading)
                    .help("刷新服务器流量")
                    .accessibilityLabel("刷新服务器流量")
                }
            }
            Button {
                openChartDetail(detailContext)
            } label: {
                Image(systemName: "chart.xyaxis.line").frame(width: 18, height: 22)
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.medium))
            .help("在菜单侧边查看详细图表")
            .accessibilityLabel("展开图表明细")
        }
        .frame(height: 29)
    }

    private func statsButton(_ title: String, icon: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).accessibilityHidden(true) }
                Text(title).lineLimit(1)
            }
            .font(.caption.weight(selected ? .semibold : .medium))
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 7)
            .frame(height: 23)
            .background(selected ? Color(nsColor: .controlBackgroundColor) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var metricsCard: some View {
        if activeTab == .live {
            TrafficDashboard(isConnected: isConnected, connectedAt: store.connectedAt,
                             traffic: store.traffic, history: store.trafficHistory)
        } else {
            let scope = metricsRequest.scope
            let completed = metricsView.completedScope == scope
            MenuHistoryCard(
                report: menuStats.report(for: scope.range, serverID: scope.dropletID), range: scope.range,
                isServer: activeTab == .server, isLoading: !completed || menuStats.isLoading,
                errorMessage: completed ? menuStats.errorMessage : nil
            )
            .id(scope)
        }
    }

    private var availableTabs: [MenuMetricsTab] {
        serverSource.dropletID == nil ? [.live, .local] : MenuMetricsTab.allCases
    }

    private var activeTab: MenuMetricsTab {
        availableTabs.contains(selectedTab) ? selectedTab : .live
    }

    private var detailContext: MenuChartDetailContext {
        let source: MenuChartDetailSource = switch activeTab {
        case .live: .live
        case .local: .local
        case .server: .server
        }
        return MenuChartDetailContext(source: source, range: selectedRange)
    }

    private var metricsRequest: MenuMetricsRequest {
        MenuMetricsRequest(
            scope: MenuMetricsScope(tab: activeTab, range: selectedRange,
                                    dropletID: activeTab == .server ? serverSource.dropletID : nil),
            revision: activeTab == .local ? store.historyRevision : 0,
            refresh: activeTab == .server ? metricsView.refresh : 0
        )
    }

    private func loadMetrics(_ request: MenuMetricsRequest) async {
        switch request.scope.tab {
        case .live:
            return
        case .local:
            await menuStats.loadLocal(store: store, range: request.scope.range)
        case .server:
            let force = request.refresh != metricsView.completedRefresh
            await menuStats.loadServer(source: serverSource, range: request.scope.range, force: force)
            if !Task.isCancelled { metricsView.completedRefresh = request.refresh }
        }
        if !Task.isCancelled { metricsView.completedScope = request.scope }
    }

    private var modePicker: some View {
        HStack(spacing: 4) {
            modeButton("全部代理", symbol: "shield", mode: .global, selected: !isRulesMode)
            modeButton("规则分流", symbol: "arrow.triangle.branch", mode: .rules, selected: isRulesMode)
        }
        .padding(3)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        .disabled(isBusy)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("连接模式")
    }

    private func modeButton(_ title: String, symbol: String, mode: TunnelMode, selected: Bool) -> some View {
        Button {
            store.selectMode(mode)
        } label: {
            Label(title, systemImage: symbol)
                .font(.callout.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(
                    selected ? Color(nsColor: .controlBackgroundColor) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(action: openHistory) {
                Label("流量统计", systemImage: "chart.bar.xaxis")
            }

            Button(action: store.importProfile) {
                Label("导入配置…", systemImage: "folder")
            }
            .disabled(!isDisconnected)

            Button(action: openEditor) {
                Label("编辑规则…", systemImage: "slider.horizontal.3")
            }
            .disabled(!isDisconnected)

            Spacer(minLength: 0)

            Button(action: store.quit) {
                Image(systemName: "power")
            }
            .disabled(isBusy)
            .help("退出 TunnelMaster")
            .accessibilityLabel("退出 TunnelMaster")
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }

    private var rulesEditor: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("分流规则")
                    .font(.headline)
                Spacer()
                Button("返回") { editor.isEditing = false }
                    .buttonStyle(.borderless)
            }

            Text("每行填写一个域名，规则同时匹配其子域名。")
                .font(.caption)
                .foregroundStyle(.secondary)

            domainEditor("始终直连", example: "bilibili.com", domains: $editor.directDomains)
            domainEditor("始终走隧道", example: "example.com", domains: $editor.proxyDomains)

            Toggle("中国大陆 IP 直连", isOn: $editor.chinaIPDirect)
                .font(.callout)

            if editor.showingError, let error = store.errorMessage {
                notice(error, symbol: "exclamationmark.circle", color: .orange)
            }

            HStack {
                Spacer()
                Button("取消") { editor.isEditing = false }
                Button("保存") {
                    if store.saveRules(direct: editor.directDomains, proxy: editor.proxyDomains, china: editor.chinaIPDirect) {
                        editor.isEditing = false
                    } else {
                        editor.showingError = true
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func domainEditor(_ title: String, example: String, domains: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.callout.weight(.medium))

            ZStack(alignment: .topLeading) {
                if domains.wrappedValue.isEmpty {
                    Text(example)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }

                TextEditor(text: domains)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 3)
                    .accessibilityLabel(title)
            }
            .frame(height: 64)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        }
    }

    private func openEditor() {
        editor.directDomains = store.directDomains
        editor.proxyDomains = store.proxyDomains
        editor.chinaIPDirect = store.useChinaIPRules
        editor.showingError = false
        editor.isEditing = true
    }

    private func notice(_ message: String, symbol: String, color: Color = .secondary) -> some View {
        Label(message, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var isConnected: Bool {
        if case .connected = store.status { return true }
        return false
    }

    private var isDisconnected: Bool {
        if case .disconnected = store.status { return true }
        return false
    }

    private var isBusy: Bool { store.changingMode || (!isConnected && !isDisconnected) }

    private var isRulesMode: Bool {
        if case .rules = store.mode { return true }
        return false
    }

    private var connectionUnavailable: Bool {
        !store.hasRuleEngine || store.profileName == nil || store.observedFullTunnel
    }

    private var statusColor: Color {
        switch store.status {
        case .connected: .green
        case .connecting, .disconnecting: .orange
        case .disconnected: .secondary
        }
    }

    private var statusTitle: String {
        switch store.status {
        case .connected: "已连接"
        case .connecting: "正在连接"
        case .disconnecting: "正在断开"
        case .disconnected: "已断开"
        }
    }

    private var actionTitle: String {
        if store.changingMode { return "正在切换模式…" }
        return switch store.status {
        case .connected: "断开连接"
        case .connecting: "正在连接…"
        case .disconnecting: "正在断开…"
        case .disconnected: "连接"
        }
    }
}

private enum MenuMetricsTab: String, CaseIterable, Identifiable {
    case live, local, server
    var id: Self { self }
    var title: String {
        switch self {
        case .live: "实时"
        case .local: "本机"
        case .server: "服务器"
        }
    }
    var icon: String {
        switch self {
        case .live: "waveform"
        case .local: "laptopcomputer"
        case .server: "server.rack"
        }
    }
}

private struct MenuMetricsScope: Hashable {
    let tab: MenuMetricsTab
    let range: MenuTrafficRange
    let dropletID: String?
}

private struct MenuMetricsRequest: Equatable {
    let scope: MenuMetricsScope
    let revision: Int
    let refresh: Int
}

@MainActor
private final class MenuMetricsState: ObservableObject {
    @Published var refresh = 0
    @Published var completedScope: MenuMetricsScope?
    var completedRefresh = 0
}

@MainActor
private final class RuleEditorState: ObservableObject {
    @Published var isEditing = false
    @Published var directDomains = ""
    @Published var proxyDomains = ""
    @Published var chinaIPDirect = true
    @Published var showingError = false
}
