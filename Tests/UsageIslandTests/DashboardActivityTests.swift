import AppKit
import Combine
import SwiftUI
import XCTest
@testable import UsageIsland

@MainActor
final class DashboardActivityTests: XCTestCase {
    private final class Driver: ObservableObject {
        @Published var active = false
        @Published var revision = 0
        var contentBuilds: [UUID] = []
    }

    /// The selection lives on the tab owner, as it does in QuotaHistoryView.
    /// Rebuilding a hidden owner must neither evaluate the chart nor reset state.
    private struct TabOwner: View {
        @ObservedObject var driver: Driver
        @State private var selectionIdentity = UUID()
        var body: some View {
            let revision = driver.revision
            ActiveDashboardContent(isActive: driver.active) {
                recordBuild(revision: revision)
            }
        }
        private func recordBuild(revision: Int) -> some View {
            driver.contentBuilds.append(selectionIdentity)
            return Text("Chart revision \(revision)")
        }
    }

    func testInactiveTabSkipsContentAndRetainsOwningStateAcrossNavigation() {
        let driver = Driver()
        let host = NSHostingView(rootView: TabOwner(driver: driver).frame(width: 400, height: 200))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func update() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: .now.addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded()
        }
        update()
        XCTAssertTrue(driver.contentBuilds.isEmpty, "An unselected tab must not build its expensive content")
        driver.active = true
        update()
        XCTAssertFalse(driver.contentBuilds.isEmpty)
        let originalSelection = driver.contentBuilds.first
        driver.active = false
        update()
        let buildsBeforeHiddenUpdate = driver.contentBuilds.count
        driver.revision += 1
        update()
        XCTAssertEqual(driver.contentBuilds.count, buildsBeforeHiddenUpdate,
                       "Publishing new data while hidden must not reconstruct the chart")
        driver.active = true
        update()
        XCTAssertGreaterThan(driver.contentBuilds.count, buildsBeforeHiddenUpdate)
        XCTAssertEqual(driver.contentBuilds.last, originalSelection,
                       "Returning to a tab must preserve its owning selection state")
    }
}
