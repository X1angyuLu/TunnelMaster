import AppKit
import SwiftUI

/// Receives pointer movement in the menu's panel even when the panel isn't key.
/// Hit testing stays with the SwiftUI chart controls underneath.
struct MenuChartPointer: NSViewRepresentable {
    var register: ((TrackingView) -> Void)?
    let onMove: (CGPoint?, NSView) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMove = onMove
        register?(view)
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onMove = onMove
        register?(view)
    }

    static func dismantleNSView(_ view: TrackingView, coordinator: ()) {
        view.onMove = nil
    }

    final class TrackingView: NSView {
        var onMove: ((CGPoint?, NSView) -> Void)?
        private var pointerArea: NSTrackingArea?
        private var lastPoint: CGPoint?

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let pointerArea { removeTrackingArea(pointerArea) }
            let area = NSTrackingArea(
                rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                owner: self, userInfo: nil
            )
            addTrackingArea(area)
            pointerArea = area
        }

        override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

        override func mouseMoved(with event: NSEvent) {
            report(convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) { clearPointer() }

        func samplePointer() {
            guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else {
                clearPointer()
                return
            }
            report(convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
        }

        func clearPointer() { report(nil) }

        private func report(_ point: CGPoint?) {
            let visiblePoint = point.flatMap { visibleRect.contains($0) ? $0 : nil }
            guard visiblePoint != lastPoint else { return }
            lastPoint = visiblePoint
            onMove?(visiblePoint, self)
        }
    }
}
