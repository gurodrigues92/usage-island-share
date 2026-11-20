import AppKit

/// The app's vertical island and three rings, simplified for the menu bar.
enum MenuBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let island = NSBezierPath(
                roundedRect: NSRect(x: 6.25, y: 0.75, width: 9.5, height: 16.5),
                xRadius: 4.75, yRadius: 4.75
            )
            island.lineWidth = 1.25
            island.stroke()

            for y in [2.75, 7.25, 11.75] {
                let ring = NSBezierPath(ovalIn: NSRect(x: 9.25, y: y, width: 3.5, height: 3.5))
                ring.lineWidth = 1
                ring.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Usage Island"
        return image
    }
}
