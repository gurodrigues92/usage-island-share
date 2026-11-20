import AppKit
import SwiftUI
import XCTest
@testable import UsageIsland

@MainActor
final class WidgetInteractionTests: XCTestCase {
    func testNonactivatingPanelAcceptsFirstClickAndKeepsTransparentAreaClickThrough() throws {
        let suite = "UsageIsland-FirstClick-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = IslandModel(settings: UsageSettings(defaults: defaults, initial: UsageSettings.defaults(profiles: [.padrao])),
                                history: UsageHistory(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                                defaults: defaults, profiles: [.padrao])
        let host = IslandHostingView(rootView: IslandView(model: model))
        host.model = model
        host.frame = NSRect(x: 0, y: 0, width: 92, height: model.fullMetrics.islandHeight)
        XCTAssertTrue(host.acceptsFirstMouse(for: nil), "The widget never activates, so the first click must reach its controls")
        XCTAssertNil(host.hitTest(NSPoint(x: 1, y: 1)), "Transparent space must keep passing clicks to the underlying app")
    }

    func testSettingsFooterStaysClearOfLastRingAndTransparentFlareAtAllWidths() {
        for width: CGFloat in [40, 72, 92, 130] {
            for rings in [1, 4, 12] {
                let metrics = IslandMetrics(railWidth: width, showsPercent: true, ringCount: CGFloat(rings))
                let lastRingBottom = metrics.contentInset + metrics.ringBlockHeight + metrics.ringPitch * CGFloat(rings - 1)
                let buttonBottom = metrics.islandHeight - metrics.flareHeight - 4
                XCTAssertGreaterThanOrEqual(buttonBottom - 28, lastRingBottom + 8)
                XCTAssertLessThan(buttonBottom, metrics.islandHeight - metrics.flareHeight)
            }
        }
        XCTAssertEqual(IslandMetrics.compact(rings: 4).settingsFooterHeight, 0)
    }

    func testReopeningWindowDetectsDisconnectedScreenAndHiddenTitlebar() {
        let main = NSRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertTrue(IslandWindowPresentation.hasVisibleTitlebar(NSRect(x: 200, y: 100, width: 820, height: 700), screens: [main]))
        XCTAssertFalse(IslandWindowPresentation.hasVisibleTitlebar(NSRect(x: 1900, y: 100, width: 820, height: 700), screens: [main]))
        XCTAssertFalse(IslandWindowPresentation.hasVisibleTitlebar(NSRect(x: 200, y: 880, width: 820, height: 700), screens: [main]))
        let second = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        XCTAssertTrue(IslandWindowPresentation.hasVisibleTitlebar(NSRect(x: -1400, y: 100, width: 820, height: 700), screens: [main, second]))
    }
}
