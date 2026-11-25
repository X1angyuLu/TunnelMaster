import SwiftUI

@MainActor
struct MenuView: View {
    @ObservedObject var store: TunnelStore
    @StateObject private var editor = RuleEditorState()

    var body: some View {
        Group {
            if editor.isEditing {
                rulesEditor
            } else {
                overview
            }
        }
        .padding(16)
        .frame(width: 350)
        .onAppear { store.refresh() }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            connectionCard
            modePicker

            VStack(alignment: .leading, spacing: 6) {
                Text(routingFootnote)
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
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "network")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)

            Text("TunnelMenu")
                .font(.system(.headline, design: .rounded))

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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label("配置", systemImage: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(store.profileName ?? "尚未选择")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 11)
            .frame(minHeight: 38)

            Divider().padding(.leading, 11)

            HStack(spacing: 8) {
                Label("出口 IP", systemImage: "globe.americas")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(store.exitIP ?? "—")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)

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
            .padding(.horizontal, 11)
            .frame(minHeight: 38)
        }
        .font(.callout)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private var modePicker: some View {
        HStack(spacing: 4) {
            modeButton("全部代理", symbol: "shield", mode: .global, selected: !isRulesMode)
            modeButton("规则分流", symbol: "arrow.triangle.branch", mode: .rules, selected: isRulesMode)
        }
        .padding(3)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        .disabled(!isDisconnected)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("连接模式")
    }

    private func modeButton(_ title: String, symbol: String, mode: TunnelMode, selected: Bool) -> some View {
        Button {
            store.mode = mode
            store.refresh()
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
            .help("退出 TunnelMenu")
            .accessibilityLabel("退出 TunnelMenu")
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

    private var isBusy: Bool { !isConnected && !isDisconnected }

    private var isRulesMode: Bool {
        if case .rules = store.mode { return true }
        return false
    }

    private var connectionUnavailable: Bool {
        !store.hasRuleEngine || store.profileName == nil || store.observedFullTunnel
    }

    private var routingFootnote: String {
        if isRulesMode {
            "遵循 macOS 系统代理的应用按规则分流。"
        } else {
            "遵循 macOS 系统代理的应用经隧道联网。"
        }
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
        switch store.status {
        case .connected: "断开连接"
        case .connecting: "正在连接…"
        case .disconnecting: "正在断开…"
        case .disconnected: "连接"
        }
    }
}

@MainActor
private final class RuleEditorState: ObservableObject {
    @Published var isEditing = false
    @Published var directDomains = ""
    @Published var proxyDomains = ""
    @Published var chinaIPDirect = true
    @Published var showingError = false
}
