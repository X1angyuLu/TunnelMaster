import AppKit
import SwiftUI

@MainActor
final class MenuChartDetailController {
    var onPointerLeft: (@MainActor () -> Void)?

    var isPointerInside: Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.contains(NSEvent.mouseLocation)
    }

    private let store: TunnelStore
    private let selection = MenuChartDetailSelection()
    private weak var anchor: NSView?
    private weak var suppressedAnchor: NSView?
    private var context: MenuChartDetailContext?
    private var displayedContext: MenuChartDetailContext?
    private var isOverPlot = false
    private var panel: MenuChartDetailPanel?
    private var host: MenuChartDetailHost?
    private var previewTask: Task<Void, Never>?
    private var dismissalTask: Task<Void, Never>?
    private weak var pointerView: MenuChartPointer.TrackingView?
    private var pointerSampling: Task<Void, Never>?

    init(store: TunnelStore) {
        self.store = store
    }

    func registerPointerView(_ view: MenuChartPointer.TrackingView) {
        pointerView = view
    }

    func startPointerSampling() {
        guard pointerSampling == nil else { return }
        // Menu panels may receive a mouse position without a mouse-moved event.
        // Sample only while the parent menu is shown and keep input local to its chart.
        pointerSampling = Task { [weak self] in
            while !Task.isCancelled, let self {
                if isPointerInside {
                    pointerView?.clearPointer()
                } else {
                    pointerView?.samplePointer()
                }
                do { try await Task.sleep(for: .milliseconds(60)) }
                catch { return }
            }
        }
    }

    func stopPointerSampling() {
        pointerSampling?.cancel()
        pointerSampling = nil
        pointerView?.clearPointer()
    }

    func pointerChanged(anchor: NSView, context: MenuChartDetailContext, isOverPlot: Bool, selectedDate: Date?) {
        if !isOverPlot {
            if suppressedAnchor === anchor { suppressedAnchor = nil }
            guard self.anchor === anchor else { return }
            self.isOverPlot = false
            cancelPreview()
            scheduleDismissal()
            return
        }

        guard suppressedAnchor !== anchor, anchor.window?.isVisible == true else { return }
        self.anchor = anchor
        self.context = context
        self.isOverPlot = true
        if selection.selectedDate != selectedDate { selection.selectedDate = selectedDate }
        cancelDismissal()

        if panel?.isVisible == true {
            if displayedContext != context || panel?.parent !== anchor.window { showPanel(takeKeyboard: false) }
        } else if previewTask == nil {
            previewTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !Task.isCancelled else { return }
                previewTask = nil
                if self.isOverPlot { showPanel(takeKeyboard: false) }
            }
        }
    }

    func open(anchor: NSView, context: MenuChartDetailContext, selectedDate: Date?) {
        guard anchor.window?.isVisible == true else { return }
        self.anchor = anchor
        self.context = context
        isOverPlot = false
        suppressedAnchor = nil
        if selection.selectedDate != selectedDate { selection.selectedDate = selectedDate }
        cancelPreview()
        cancelDismissal()
        showPanel(takeKeyboard: true)
    }

    func dismiss() {
        cancelPreview()
        cancelDismissal()
        isOverPlot = false
        suppressedAnchor = nil
        anchor = nil
        context = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentView = nil
        }
        host = nil
        displayedContext = nil
        selection.selectedDate = nil
    }

    private func closeFromDetail() {
        let anchorToSuppress = isOverPlot ? anchor : nil
        dismiss()
        suppressedAnchor = anchorToSuppress
        onPointerLeft?()
    }

    private func showPanel(takeKeyboard: Bool) {
        guard let parent = anchor?.window, parent.isVisible,
              let context, let screen = parent.screen ?? NSScreen.main else { return }
        let panel = panelForContext(context)
        if panel.parent !== parent || !panel.isVisible {
            panel.parent?.removeChildWindow(panel)
            panel.level = parent.level
            panel.setFrame(Self.attachedFrame(parent: parent.frame, visible: screen.visibleFrame), display: false)
            parent.addChildWindow(panel, ordered: .above)
            panel.orderFrontRegardless()
        }
        if takeKeyboard { panel.makeKey() }
    }

    private func panelForContext(_ context: MenuChartDetailContext) -> MenuChartDetailPanel {
        if let panel, let host {
            if displayedContext != context {
                host.rootView = detailContent(context)
                displayedContext = context
            }
            return panel
        }

        let host = MenuChartDetailHost(rootView: detailContent(context))
        host.sizingOptions = []
        host.pointerMoved = { [weak self] inside in
            if inside {
                self?.cancelDismissal()
            } else {
                self?.scheduleDismissal()
                self?.onPointerLeft?()
            }
        }

        let panel = self.panel ?? makePanel()
        panel.contentView = host
        self.panel = panel
        self.host = host
        displayedContext = context
        return panel
    }

    private func makePanel() -> MenuChartDetailPanel {
        let panel = MenuChartDetailPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.title = "流量图表详情"
        panel.becomesKeyOnlyIfNeeded = true
        panel.isExcludedFromWindowsMenu = true
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.closeDetail = { [weak self] in self?.closeFromDetail() }
        return panel
    }

    private func detailContent(_ context: MenuChartDetailContext) -> MenuChartDetailView {
        MenuChartDetailView(store: store, context: context, selection: selection) { [weak self] in
            self?.closeFromDetail()
        }
    }

    private func scheduleDismissal() {
        guard panel?.isVisible == true, dismissalTask == nil else { return }
        dismissalTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 420_000_000)
            guard let self, !Task.isCancelled else { return }
            dismissalTask = nil
            if !isOverPlot, !isPointerInside {
                dismiss()
                onPointerLeft?()
            }
        }
    }

    private func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
    }

    private func cancelDismissal() {
        dismissalTask?.cancel()
        dismissalTask = nil
    }

    private static func attachedFrame(parent: NSRect, visible: NSRect) -> NSRect {
        let safe = visible.insetBy(dx: 8, dy: 8)
        let gap: CGFloat = 8
        let preferredSize = MenuChartDetailView.size
        let left = parent.minX - safe.minX - gap
        let right = safe.maxX - parent.maxX - gap
        let placeLeft = left >= preferredSize.width || (right < preferredSize.width && left >= right)
        let available = placeLeft ? left : right
        // On a narrow display, retain a readable minimum even if the windows must overlap.
        let width = min(safe.width, preferredSize.width, max(345, available))
        let height = min(safe.height, preferredSize.height)
        let proposedX = placeLeft ? parent.minX - gap - width : parent.maxX + gap
        let x = min(max(proposedX, safe.minX), safe.maxX - width)
        let y = min(max(parent.maxY - height, safe.minY), safe.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

@MainActor
private final class MenuChartDetailPanel: NSPanel {
    var closeDetail: (@MainActor () -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        closeDetail?()
    }
}

@MainActor
private final class MenuChartDetailHost: NSHostingView<MenuChartDetailView> {
    var pointerMoved: (@MainActor (Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let replacement = NSTrackingArea(
            rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil
        )
        tracking = replacement
        addTrackingArea(replacement)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === tracking { pointerMoved?(true) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === tracking { pointerMoved?(false) }
    }
}
