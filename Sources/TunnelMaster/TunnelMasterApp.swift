import AppKit
import SwiftUI

@main
@MainActor
struct TunnelMasterApp: App {
    @StateObject private var store = TunnelStore()
    private static let connectedGlobe = globeImage(opacity: 1)
    private static let disconnectedGlobe = globeImage(opacity: 0.45)

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store)
        } label: {
            Label {
                Text("TunnelMaster")
            } icon: {
                Image(nsImage: store.status == .connected ? Self.connectedGlobe : Self.disconnectedGlobe)
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel(menuBarTitle)
        }
        .menuBarExtraStyle(.window)

        historyWindow
    }

    private var historyWindow: some Scene {
        Window("流量历史", id: "traffic-history") {
            UsageHistoryView(store: store)
        }
        .defaultSize(width: 960, height: 780)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("退出 TunnelMaster", action: store.quit)
                    .keyboardShortcut("q")
            }
        }
    }

    private static func globeImage(opacity: CGFloat) -> NSImage {
        let symbol = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!
        // The template adapts to the menu bar appearance while keeping the drawn opacity.
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: opacity)
            return true
        }
        image.isTemplate = true
        return image
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
