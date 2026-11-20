import AppKit
import Testing
@testable import UsageIsland

struct DockPlacementTests {
    @Test func minimumDockScaleLeavesPositiveSpaceForActivityArc() {
        for scale in [0.5, 0.75, 1, 1.5] {
            for rail in [CGFloat(40), 72, 92, 130] {
                let metrics = IslandMetrics(railWidth: rail * scale, showsPercent: false, ringCount: 4)
                let innerDiameter = metrics.ringDiameter - 2 * metrics.activityInset
                #expect(metrics.activityInset >= 0)
                #expect(innerDiameter >= 2 * metrics.activityStroke - 0.000001)
                #expect(innerDiameter > 0)
            }
        }
    }

    @Test func savedVerticalPositionRoundTripsOnEitherEdgeAndOffsetScreens() {
        let screens = [NSRect(x: 0, y: 48, width: 1440, height: 850),
                       NSRect(x: -1920, y: -300, width: 1920, height: 1040)]
        for screen in screens {
            for edge in [IslandEdge.left, .right] {
                for position in [0.0, 0.15, 0.5, 0.85, 1.0] {
                    let frame = IslandPlacement.frame(size: NSSize(width: 92, height: 540 + 28),
                        visible: screen, edge: edge, position: position)
                    #expect(abs(IslandPlacement.position(for: frame, visible: screen) - position) < 0.000001)
                    #expect(screen.contains(frame))
                }
            }
        }
    }

    @Test func dragUsesInitialScreenCoordinatesWithoutAccumulatingOrFollowingHorizontalMotion() {
        let screen = NSRect(x: -1920, y: -300, width: 1920, height: 1040)
        let initial = NSRect(x: -92, y: -50, width: 92, height: 480)
        let drag = DockDragSession(startPoint: NSPoint(x: -40, y: 0), initialFrame: initial, visibleFrame: screen)
        let first = drag.frame(at: NSPoint(x: 900, y: 40))
        let repeated = drag.frame(at: NSPoint(x: 1800, y: 40))
        #expect(first == repeated)
        #expect(first.origin == NSPoint(x: initial.minX, y: initial.minY + 40))
        #expect(drag.frame(at: NSPoint(x: -40, y: 0)) == initial)
    }

    @Test func draggingStopsAtBothVisibleEdgesAndKeepsHandleInsideScreen() {
        let screen = NSRect(x: 0, y: 48, width: 1440, height: 850)
        let frame = NSRect(x: 1348, y: 180, width: 92, height: 568)
        let top = IslandPlacement.verticallyMoved(frame, delta: 10_000, visible: screen)
        let bottom = IslandPlacement.verticallyMoved(frame, delta: -10_000, visible: screen)
        #expect(top.maxY == screen.maxY)
        #expect(bottom.minY == screen.minY)
        #expect(top.size == frame.size)
        #expect(bottom.minX == frame.minX)
        #expect(IslandPlacement.position(for: top, visible: screen) == 0)
        #expect(IslandPlacement.position(for: bottom, visible: screen) == 1)
        #expect(IslandPlacement.verticallyMoved(frame, delta: .nan, visible: screen) == frame)
    }

    @Test func zeroTravelAndHiddenStripGeometryStaySafe() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(IslandPlacement.position(for: screen, visible: screen) == 0.5)
        let panel = NSRect(x: 980, y: 80, width: 460, height: 650)
        let strip = IslandPlacement.interactionFrame(in: panel, size: NSSize(width: 8, height: 140), edge: .right)
        #expect(strip.maxX == panel.maxX)
        #expect(strip.midY == panel.midY)
        #expect(!strip.contains(NSPoint(x: panel.minX + 50, y: panel.midY)))
        let left = IslandPlacement.interactionFrame(in: panel, size: NSSize(width: 40, height: 280), edge: .left)
        #expect(left.minX == panel.minX)
        #expect(left.height == 280)
        #expect(left.contains(NSPoint(x: left.midX, y: left.minY + 4)))
    }

    @Test func completionNoticeHitAreaExcludesTransparentSpaceAboveBelowAndBetweenRail() {
        let panel = NSRect(x: 980, y: 80, width: 442, height: 650)
        for edge in [IslandEdge.left, .right] {
            let rail = IslandPlacement.interactionFrame(in: panel, size: NSSize(width: 8, height: 140), edge: edge)
            let notice = IslandPlacement.noticeFrame(in: panel, railWidth: 8, height: 144, edge: edge)
            #expect(notice.width == 332)
            #expect(notice.height == 144)
            #expect(notice.midY == panel.midY)
            #expect(!notice.intersects(rail))
            #expect(!notice.contains(NSPoint(x: notice.midX, y: panel.maxY - 4)))
            #expect(!notice.contains(NSPoint(x: notice.midX, y: panel.minY + 4)))
            #expect(edge == .left ? notice.minX - rail.maxX == 18 : rail.minX - notice.maxX == 18)
        }
    }
}
