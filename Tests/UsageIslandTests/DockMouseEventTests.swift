import AppKit
import XCTest
@testable import UsageIsland

@MainActor
final class DockMouseEventTests: XCTestCase {
    func testQueuedDragUsesCapturedEventPositionsWithoutMovingLiveCursor() throws {
        let handle = DockDragHandle.HandleView(frame: NSRect(x: 0, y: 0, width: 28, height: 26))
        var phases: [DockDragPhase] = []
        var points: [NSPoint] = []
        handle.onDrag = { phases.append($0); points.append($1) }
        func event(_ type: CGEventType, _ y: CGFloat) throws -> NSEvent {
            let cg = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: CGPoint(x: 350, y: y), mouseButton: .left))
            return try XCTUnwrap(NSEvent(cgEvent: cg))
        }
        // These events are never posted to the OS and do not move the user's pointer.
        handle.mouseDown(with: try event(.leftMouseDown, 400))
        handle.mouseDragged(with: try event(.leftMouseDragged, 370))
        handle.mouseUp(with: try event(.leftMouseUp, 370))
        XCTAssertEqual(phases, [.begin, .change, .end])
        XCTAssertEqual(points[1].y - points[0].y, 30, accuracy: 0.001)
        XCTAssertEqual(points[1], points[2])
        XCTAssertEqual(points[0].x, 350, accuracy: 0.001)
    }
}
