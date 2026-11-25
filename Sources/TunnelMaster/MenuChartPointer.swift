import AppKit
import SwiftUI

/// Receives pointer movement in the menu's panel even when the panel isn't key.
/// Hit testing stays with the SwiftUI chart controls underneath.
struct MenuChartPointer: NSViewRepresentable {
    let onMove: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMove = onMove
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onMove = onMove
    }

    static func dismantleNSView(_ view: TrackingView, coordinator: ()) {
        view.onMove = nil
    }

    final class TrackingView: NSView {
        var onMove: ((CGPoint?) -> Void)?
        private var pointerArea: NSTrackingArea?

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
            let point = convert(event.locationInWindow, from: nil)
            onMove?(bounds.contains(point) ? point : nil)
        }

        override func mouseExited(with event: NSEvent) { onMove?(nil) }
    }
}
