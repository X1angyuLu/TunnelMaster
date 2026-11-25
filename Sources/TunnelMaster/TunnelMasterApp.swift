import AppKit
import SwiftUI

@main
@MainActor
struct TunnelMasterApp: App {
    @NSApplicationDelegateAdaptor(TunnelMasterDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {}
                CommandGroup(replacing: .appTermination) {
                    Button("退出 TunnelMaster", action: delegate.quit)
                        .keyboardShortcut("q")
                }
            }
    }
}

@MainActor
final class TunnelMasterDelegate: NSObject, NSApplicationDelegate {
    private lazy var store = TunnelStore()
    private var statusPopover: StatusPopoverController?
    private var historyWindow: NSWindowController?
    private var pendingPopover = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusPopover = StatusPopoverController(store: store) { [weak self] in
            self?.showHistory()
        }
        if pendingPopover { statusPopover?.showPinned() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "tunnelmaster" {
            switch (url.host, url.path) {
            case ("menu", ""):
                openPopover()
            case ("statistics", ""), ("statistics", "/"):
                showHistory()
            case ("statistics", "/digitalocean"):
                UsageHistoryView.selectDigitalOcean()
                showHistory()
            default:
                continue
            }
        }
    }

    func applicationShouldHandleReopen(_ application: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openPopover() }
        return false
    }

    func quit() {
        store.quit()
    }

    private func openPopover() {
        if let statusPopover {
            statusPopover.showPinned()
        } else {
            pendingPopover = true
        }
    }

    private func showHistory() {
        if historyWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 780),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "流量历史"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 760, height: 610)
            window.contentViewController = NSHostingController(rootView: UsageHistoryView(store: store))
            window.center()
            window.setFrameAutosaveName("traffic-history")
            historyWindow = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.showWindow(nil)
        historyWindow?.window?.makeKeyAndOrderFront(nil)
    }
}
