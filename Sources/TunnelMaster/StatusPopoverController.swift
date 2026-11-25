import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusPopoverController: NSObject, NSPopoverDelegate {
    private enum Presentation { case preview, pinned }

    private static let connectedGlobe = globeImage(opacity: 1)
    private static let disconnectedGlobe = globeImage(opacity: 0.45)

    private let store: TunnelStore
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let hosting: NSHostingController<MenuView>
    private var statusObservation: AnyCancellable?
    private var buttonTracking: NSTrackingArea?
    private var panelTracking: NSTrackingArea?
    private weak var panelTrackingView: NSView?
    private var presentation: Presentation?
    private var previewTask: Task<Void, Never>?
    private var dismissalTask: Task<Void, Never>?

    init(store: TunnelStore, openHistory: @escaping @MainActor () -> Void) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        hosting = NSHostingController(rootView: MenuView(store: store, openHistory: openHistory))
        super.init()

        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageOnly
            let area = trackingArea()
            button.addTrackingArea(area)
            buttonTracking = area
        }

        statusObservation = store.$status.sink { [weak self] status in
            self?.updateButton(for: status)
        }
    }

    func showPinned() {
        show(.pinned)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown, presentation == .pinned {
            cancelPreview()
            cancelDismissal()
            popover.close()
        } else {
            showPinned()
        }
    }

    private func show(_ style: Presentation) {
        cancelPreview()
        cancelDismissal()
        guard let button = statusItem.button, button.window?.isVisible == true else { return }
        presentation = style
        if !popover.isShown {
            popover.contentSize = hosting.view.fittingSize
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        if style == .pinned {
            hosting.view.window?.makeKey()
        }
    }

    private func trackingArea() -> NSTrackingArea {
        NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited],
                       owner: self, userInfo: nil)
    }

    @objc(mouseEntered:)
    private func pointerEntered(_ event: NSEvent) {
        if event.trackingArea === buttonTracking {
            cancelDismissal()
            guard !popover.isShown, previewTask == nil else { return }
            previewTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 310_000_000)
                guard let self, !Task.isCancelled else { return }
                previewTask = nil
                if containsPointer(statusItem.button), !popover.isShown {
                    show(.preview)
                }
            }
        } else if event.trackingArea === panelTracking {
            cancelDismissal()
        }
    }

    @objc(mouseExited:)
    private func pointerExited(_ event: NSEvent) {
        if event.trackingArea === buttonTracking {
            cancelPreview()
        } else if event.trackingArea !== panelTracking {
            return
        }
        guard presentation == .preview, dismissalTask == nil else { return }

        dismissalTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            dismissalTask = nil
            if presentation == .preview, !containsPointer(statusItem.button), !containsPointer(panelTrackingView) {
                popover.close()
            }
        }
    }

    private func containsPointer(_ view: NSView?) -> Bool {
        guard let view, let window = view.window, window.isVisible else { return false }
        let location = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return view.bounds.contains(view.convert(location, from: nil))
    }

    private func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
    }

    private func cancelDismissal() {
        dismissalTask?.cancel()
        dismissalTask = nil
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        // The anchor's own action decides whether to pin the preview or close it.
        guard let type = NSApp.currentEvent?.type, type == .leftMouseDown || type == .leftMouseUp else { return true }
        return !containsPointer(statusItem.button)
    }

    func popoverDidShow(_ notification: Notification) {
        let view = hosting.view
        let area = trackingArea()
        view.addTrackingArea(area)
        panelTracking = area
        panelTrackingView = view
    }

    func popoverDidClose(_ notification: Notification) {
        cancelPreview()
        cancelDismissal()
        if let area = panelTracking { panelTrackingView?.removeTrackingArea(area) }
        panelTracking = nil
        panelTrackingView = nil
        presentation = nil
        store.setMetricsVisible(false)
    }

    private func updateButton(for status: ConnectionStatus) {
        let title = switch status {
        case .connected: "已连接"
        case .connecting: "正在连接"
        case .disconnecting: "正在断开"
        case .disconnected: "已断开"
        }
        statusItem.button?.image = status == .connected ? Self.connectedGlobe : Self.disconnectedGlobe
        statusItem.button?.setAccessibilityLabel("TunnelMaster，\(title)")
    }

    private static func globeImage(opacity: CGFloat) -> NSImage {
        let symbol = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: opacity)
            return true
        }
        image.isTemplate = true
        return image
    }
}
