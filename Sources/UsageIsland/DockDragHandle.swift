import AppKit
import SwiftUI

/// All dimensions follow the dock width. The two ends of the open arc straddle
/// the tip of the rail; the wider invisible stroke is the mouse target.
struct DockGripGeometry {
    let width: CGFloat
    private var profileScale: CGFloat { width / 84.8 }
    var strokeScale: CGFloat { width / 59 }
    var hitWidth: CGFloat { 20 * strokeScale }
    var footer: CGFloat { 16.5 * profileScale + hitWidth / 2 }
    var overlap: CGFloat { 17.8 * profileScale + hitWidth / 2 + 3 * strokeScale }

    func arc(in bounds: NSRect, edge: IslandEdge, lift: CGFloat = 0) -> CGPath {
        let right = edge == .right
        let center = CGPoint(x: right ? bounds.maxX - 49.6 * profileScale : bounds.minX + 49.6 * profileScale,
                             y: bounds.minY + footer - 16.5 * profileScale + lift * strokeScale)
        let path = CGMutablePath()
        path.addArc(center: center, radius: 34.3 * profileScale, startAngle: .pi / 2,
                    endAngle: right ? 0 : .pi, clockwise: right)
        return path
    }

    func target(in bounds: NSRect, edge: IslandEdge) -> CGPath {
        arc(in: bounds, edge: edge).copy(strokingWithWidth: hitWidth, lineCap: .round, lineJoin: .round, miterLimit: 1)
    }
}

enum DockDragPhase: Equatable { case begin, change, end, cancel }

/// Native mouse tracking keeps the drag attached to the pointer while the nonactivating
/// panel moves. A SwiftUI translation in the moving view's coordinate space would drift.
struct DockDragHandle: NSViewRepresentable {
    var edge: IslandEdge = .right
    var onDrag: ((DockDragPhase, NSPoint) -> Void)?

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.edge = edge
        view.onDrag = onDrag
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.edge = edge
        view.onDrag = onDrag
    }

    final class HandleView: NSView {
        var edge: IslandEdge = .right {
            didSet { if edge != oldValue { needsDisplay = true } }
        }
        var onDrag: ((DockDragPhase, NSPoint) -> Void)?
        private var dragging = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            toolTip = "Arraste para cima ou para baixo. Use as setas para ajustar a posição."
            setAccessibilityElement(true)
            setAccessibilityRole(.slider)
            setAccessibilityLabel("Arrastar Usage Island para cima ou para baixo")
            setAccessibilityHelp("Arraste pela borda da tela ou use as ações de aumentar e diminuir para mover a barra.")
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private var pointerOnArc = false
        private var area: NSTrackingArea?
        @objc dynamic var lift: CGFloat = 0 { didSet { needsDisplay = true } }

        override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
            if key == "lift" { return CABasicAnimation(keyPath: key) }
            return super.defaultAnimation(forKey: key)
        }

        private func updateAppearance() {
            let next: CGFloat = dragging ? 3 : pointerOnArc ? 2 : 0
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                lift = next
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                    animator().lift = next
                }
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways,
                .mouseMoved, .mouseEnteredAndExited, .cursorUpdate], owner: self, userInfo: nil)
            addTrackingArea(tracking)
            area = tracking
        }

        private func track(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let inside = DockGripGeometry(width: bounds.width).target(in: bounds, edge: edge).contains(point)
            if pointerOnArc != inside { pointerOnArc = inside; updateAppearance() }
            if inside { (dragging ? NSCursor.closedHand : NSCursor.openHand).set() }
            else if !dragging { NSCursor.arrow.set() }
        }

        override func cursorUpdate(with event: NSEvent) { track(event) }
        override func mouseMoved(with event: NSEvent) { track(event) }
        override func mouseEntered(with event: NSEvent) { track(event) }
        override func mouseExited(with event: NSEvent) {
            pointerOnArc = false
            updateAppearance()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            guard bounds.contains(local),
                  DockGripGeometry(width: bounds.width).target(in: bounds, edge: edge).contains(local)
            else { return nil }
            return self
        }

        override func draw(_ dirtyRect: NSRect) {
            guard bounds.width > 0, let context = NSGraphicsContext.current?.cgContext else { return }
            let geometry = DockGripGeometry(width: bounds.width)
            let width = lift <= 2 ? 4 + 0.75 * lift : 5.5 + 0.5 * (lift - 2)
            context.addPath(geometry.arc(in: bounds, edge: edge, lift: lift))
            context.setLineWidth(width * geometry.strokeScale)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineCap(.round)
            context.strokePath()
        }

        override func mouseDown(with event: NSEvent) {
            guard event.buttonNumber == 0, !dragging else { return }
            window?.makeFirstResponder(self)
            dragging = true
            updateAppearance()
            NSCursor.closedHand.set()
            needsDisplay = true
            onDrag?(.begin, screenPoint(for: event))
        }

        override func mouseDragged(with event: NSEvent) {
            guard dragging else { return }
            onDrag?(.change, screenPoint(for: event))
        }

        override func mouseUp(with event: NSEvent) {
            guard dragging else { return }
            dragging = false
            updateAppearance()
            onDrag?(.end, screenPoint(for: event))
            NSCursor.openHand.set()
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }

        override func cancelOperation(_ sender: Any?) {
            guard dragging else { return }
            dragging = false
            updateAppearance()
            onDrag?(.cancel, NSEvent.mouseLocation)
            NSCursor.openHand.set()
            needsDisplay = true
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, dragging { cancelOperation(nil) }
            super.viewWillMove(toWindow: newWindow)
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 126: nudge(by: 24)
            case 125: nudge(by: -24)
            case 53: cancelOperation(nil)
            default: super.keyDown(with: event)
            }
        }

        override func accessibilityPerformIncrement() -> Bool { nudge(by: 24); return true }
        override func accessibilityPerformDecrement() -> Bool { nudge(by: -24); return true }

        private func screenPoint(for event: NSEvent) -> NSPoint {
            // Use the position captured with this event. The live cursor may already
            // be elsewhere when queued/coalesced events are delivered. Quartz uses
            // the primary display's top-left; AppKit uses its bottom-left.
            if let point = event.cgEvent?.location, let primary = NSScreen.screens.first,
               point.x.isFinite, point.y.isFinite {
                return NSPoint(x: point.x, y: primary.frame.maxY - point.y)
            }
            if let eventWindow = event.window ?? window {
                return eventWindow.convertPoint(toScreen: event.locationInWindow)
            }
            return NSEvent.mouseLocation
        }

        private func nudge(by delta: CGFloat) {
            guard !dragging, onDrag != nil else { return }
            let start = NSEvent.mouseLocation
            let end = NSPoint(x: start.x, y: start.y + delta)
            onDrag?(.begin, start)
            onDrag?(.change, end)
            onDrag?(.end, end)
        }
    }
}
