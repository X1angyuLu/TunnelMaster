import SwiftUI

@main
@MainActor
struct TunnelMasterApp: App {
    @StateObject private var store = TunnelStore()

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store)
        } label: {
            Label("TunnelMaster", systemImage: menuBarIcon)
                .labelStyle(.iconOnly)
                .accessibilityLabel(menuBarTitle)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarIcon: String {
        switch store.status {
        case .connected:
            "shield.lefthalf.filled"
        case .connecting, .disconnecting:
            "arrow.triangle.2.circlepath"
        case .disconnected:
            "network"
        }
    }

    private var menuBarTitle: String {
        switch store.status {
        case .connected: "TunnelMaster，已连接"
        case .connecting: "TunnelMaster，正在连接"
        case .disconnecting: "TunnelMaster，正在断开"
        case .disconnected: "TunnelMaster，已断开"
        }
    }
}
