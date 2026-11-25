import SwiftUI

@main
@MainActor
struct TunnelMenuApp: App {
    @StateObject private var store = TunnelStore()

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store)
        } label: {
            Label("TunnelMenu", systemImage: menuBarIcon)
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
        case .connected: "TunnelMenu，已连接"
        case .connecting: "TunnelMenu，正在连接"
        case .disconnecting: "TunnelMenu，正在断开"
        case .disconnected: "TunnelMenu，已断开"
        }
    }
}
