import AppKit
import SwiftUI
import TunnelMasterCore

@MainActor
struct MenuView: View {
    private static let aiProxyDomains = [
        "openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com", "oaistatsig.com",
        "anthropic.com", "claude.ai", "claude.com", "claudeusercontent.com"
    ]

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
    private let closeMenu: @MainActor () -> Void

    init(
        store: TunnelStore,
        openHistory: @escaping @MainActor () -> Void,
        detailController: MenuChartDetailController,
        openChartDetail: @escaping @MainActor (MenuChartDetailContext) -> Void,
        closeMenu: @escaping @MainActor () -> Void
    ) {
        self.store = store
        _serverSource = ObservedObject(wrappedValue: store.digitalOcean)
        self.openHistory = openHistory
        self.detailController = detailController
        self.openChartDetail = openChartDetail
        self.closeMenu = closeMenu
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
        .onExitCommand(perform: closeMenu)
    }

    private var overview: some View {
        let request = metricsRequest
        let monthlyRequest = DigitalOceanMonthlyTransferRequest(
            dropletID: serverSource.dropletID, monitoringRevision: serverSource.monitoringRevision,
            refresh: metricsView.refresh
        )
        return VStack(alignment: .leading, spacing: 10) {
            header
            connectionCard
            if monthlyRequest.dropletID != nil {
                DigitalOceanMonthlyTransferCard(source: serverSource, compact: true)
            }
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
                } else if store.proxyOverridden {
                    notice("当前系统代理设置已变更。", symbol: "exclamationmark.circle", color: .orange)
                } else if isDisconnected {
                    if store.observedFullTunnel {
                        notice("检测到其他 VPN 或 TUN 正在接管网络。", symbol: "info.circle")
                    } else if store.observedOtherProxy {
                        notice("当前已有其他系统代理正在使用。", symbol: "info.circle")
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
                    Text(actionTitle)
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
        .task(id: monthlyRequest) {
            guard monthlyRequest.dropletID != nil else { return }
            let force = monthlyRequest.refresh != metricsView.completedMonthlyRefresh
            metricsView.completedMonthlyRefresh = monthlyRequest.refresh
            await serverSource.loadMonthlyTransfer(force: force)
        }
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

            closeButton
        }
    }

    private var closeButton: some View {
        Button(action: closeMenu) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭菜单")
        .help("关闭菜单")
    }

    private var connectionCard: some View {
        HStack(spacing: 11) {
            VStack(alignment: .leading, spacing: 4) {
                Label("代理节点", systemImage: "point.3.connected.trianglepath.dotted")
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
                    Label("探测出口 IP", systemImage: "globe.americas")
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
                .disabled(!isConnected || store.checkingExit || isBusy)
                .help("按当前分流规则探测连接的出口 IP")
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
                    .disabled(menuStats.isLoading || serverSource.isLoadingMonthlyTransfer)
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
                report: completed ? menuStats.report(for: scope.range, serverID: scope.dropletID,
                                                     monitoringRevision: scope.monitoringRevision) : nil,
                range: scope.range,
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
                                    dropletID: activeTab == .server ? serverSource.dropletID : nil,
                                    monitoringRevision: activeTab == .server ? serverSource.monitoringRevision : nil),
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
            .disabled(isBusy)

            Button(action: openEditor) {
                Label("编辑规则…", systemImage: "slider.horizontal.3")
            }
            .disabled(isBusy)

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
                    .disabled(editor.isSaving)
                closeButton
                    .disabled(editor.isSaving)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("每行填写一个域名，规则同时匹配其子域名。")
                if isConnected {
                    Text(isRulesMode ? "保存后会应用到当前连接。" : "保存的规则会在切换到「规则分流」时生效。")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Group {
                domainEditor("始终直连", example: "bilibili.com", domains: $editor.directDomains)
                domainEditor("始终走隧道", example: "chatgpt.com", domains: $editor.proxyDomains)

                Toggle("中国大陆 IP 直连", isOn: $editor.chinaIPDirect)
                    .font(.callout)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        Text("未匹配的公网流量")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Picker("未匹配的公网流量", selection: $editor.fallback) {
                            Text("走隧道").tag(DomainRules.Fallback.proxy)
                            Text("直连").tag(DomainRules.Fallback.direct)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 148)
                    }

                    Button(action: applyAIPreset) {
                        Label("添加 OpenAI / Claude 分流预设", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    Text(editor.presetNotice ?? "追加常用域名到隧道列表，并将未匹配流量设为直连。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(editor.isSaving)

            if let error = editor.errorMessage {
                notice(error, symbol: "exclamationmark.circle", color: .orange)
            }

            HStack {
                if editor.isSaving {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在保存规则…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { editor.isEditing = false }
                    .disabled(editor.isSaving)
                Button("保存", action: saveEditorRules)
                    .buttonStyle(.borderedProminent)
                    .disabled(editor.isSaving || isBusy)
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
        editor.fallback = store.ruleFallback
        editor.presetNotice = nil
        editor.errorMessage = nil
        editor.isEditing = true
    }

    private func applyAIPreset() {
        do {
            let existing = try DomainRules.parse(
                direct: editor.directDomains, proxy: editor.proxyDomains, china: editor.chinaIPDirect
            )
            let missing = Self.aiProxyDomains.filter { !existing.proxy.contains($0) }
            let conflicts = missing.filter { domain in
                existing.direct.contains { direct in
                    domain == direct || domain.hasSuffix("." + direct) || direct.hasSuffix("." + domain)
                }
            }
            let additional = missing.filter { !conflicts.contains($0) }
            if !additional.isEmpty {
                if editor.proxyDomains.last?.isNewline == false { editor.proxyDomains.append("\n") }
                editor.proxyDomains.append(additional.joined(separator: "\n"))
            }
            editor.fallback = .direct
            editor.presetNotice = conflicts.isEmpty ? nil : "本次跳过 \(conflicts.count) 个与已有直连规则重叠的域名。"
            editor.errorMessage = nil
        } catch {
            editor.presetNotice = nil
            editor.errorMessage = error.localizedDescription
        }
    }

    private func saveEditorRules() {
        guard !editor.isSaving, !isBusy else { return }
        editor.isSaving = true
        editor.errorMessage = nil
        Task {
            defer { editor.isSaving = false }
            do {
                try await store.saveRules(
                    direct: editor.directDomains, proxy: editor.proxyDomains, china: editor.chinaIPDirect,
                    fallback: editor.fallback
                )
                editor.isEditing = false
            } catch {
                editor.errorMessage = error.localizedDescription
            }
        }
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

    private var isBusy: Bool { store.configurationChange != nil || (!isConnected && !isDisconnected) }

    private var isRulesMode: Bool {
        if case .rules = store.mode { return true }
        return false
    }

    private var connectionUnavailable: Bool {
        !store.hasRuleEngine || store.profileName == nil || store.observedFullTunnel || store.observedOtherProxy
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
        if let change = store.configurationChange { return change.title }
        if store.needsProxyRecovery && isDisconnected { return "恢复系统代理" }
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
    let monitoringRevision: Int?
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
    var completedMonthlyRefresh = 0
}

@MainActor
private final class RuleEditorState: ObservableObject {
    @Published var isEditing = false
    @Published var directDomains = ""
    @Published var proxyDomains = ""
    @Published var chinaIPDirect = true
    @Published var fallback = DomainRules.Fallback.proxy
    @Published var presetNotice: String?
    @Published var isSaving = false
    @Published var errorMessage: String?
}
