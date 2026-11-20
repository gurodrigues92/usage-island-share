import Foundation
import XCTest
@testable import UsageIsland

@MainActor
final class DockIntegrationTests: XCTestCase {
    private func fixture() throws -> (IslandModel, UsageSettings, UserDefaults) {
        let suite = "UsageIsland-DockIntegration-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let historyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: historyURL)
        }
        let settings = UsageSettings(defaults: defaults, initial: [
            .init(id: "Codex", source: .codex),
            .init(id: "Claude-work", source: .claude, accountSlug: "work", visible: false),
            .init(id: "OpenCode", source: .opencode, visible: false)
        ])
        let model = IslandModel(settings: settings, history: UsageHistory(url: historyURL),
                                defaults: defaults, profiles: [])
        return (model, settings, defaults)
    }

    private func waiting(_ id: String = "session-test") -> AgentSession {
        .init(id: id, name: "Projeto de teste", detail: "Terminal", state: .waiting,
              waitingFor: "Resposta necessária", since: .now)
    }

    func testWaitingRevealsExactHiddenAccountWithoutChangingSavedVisibility() throws {
        let (model, settings, defaults) = try fixture()
        // Initial defaults live in memory until the user edits a preference.
        // Establish a saved hidden account before checking that activity leaves it alone.
        settings.editRing("Claude-work") { $0.name = "Conta de trabalho" }
        let savedBeforeActivity = try XCTUnwrap(defaults.data(forKey: UsageSettings.storageKey))
        XCTAssertEqual(model.snapshots.map(\.id), ["Codex"])
        model.receiveClaudeActivity(SessionActivity(sessions: [waiting("claude.123")]), entryID: "Claude-work")
        XCTAssertEqual(model.snapshots.map(\.id), ["Codex", "Claude-work"])
        XCTAssertEqual(model.dockActivity.waitingEntryIDs, ["Claude-work"])
        XCTAssertTrue(model.dockNeedsAttention)
        XCTAssertEqual(defaults.data(forKey: UsageSettings.storageKey), savedBeforeActivity)
        XCTAssertEqual(UsageSettings(defaults: defaults).value.rings.first { $0.id == "Claude-work" }?.visible, false)

        settings.edit { $0.dock.showNewActivity = false }
        XCTAssertEqual(model.snapshots.map(\.id), ["Codex"])
        settings.edit { $0.dock.showNewActivity = true }
        XCTAssertEqual(model.snapshots.map(\.id), ["Codex", "Claude-work"])
        model.receiveClaudeActivity(nil, entryID: "Claude-work")
        XCTAssertEqual(model.snapshots.map(\.id), ["Codex"])
        XCTAssertFalse(model.dockNeedsAttention)
    }

    func testDisablingTemporarilyVisibleProviderHidesItAndClosesItsCard() throws {
        let (model, settings, _) = try fixture()
        model.receiveExternalActivity([.opencode: [waiting("opencode.123.test")]])
        XCTAssertTrue(model.snapshots.contains { $0.id == "OpenCode" })
        model.select("OpenCode")
        XCTAssertTrue(model.isExpanded)
        XCTAssertEqual(model.selected, "OpenCode")

        settings.editRing("OpenCode") { $0.enabled = false }
        XCTAssertFalse(model.snapshots.contains { $0.id == "OpenCode" })
        XCTAssertFalse(model.dockActivity.waitingEntryIDs.contains("OpenCode"))
        XCTAssertFalse(model.isExpanded)
        XCTAssertNil(model.selected)
        model.receiveExternalActivity([.opencode: [waiting("opencode.123.test")]])
        XCTAssertFalse(model.snapshots.contains { $0.id == "OpenCode" })
        model.isPointerOverIsland = { false }
        model.tickIdleWatchdog(now: .now)
        model.tickIdleWatchdog(now: .now.addingTimeInterval(100))
    }

    func testRemovingRevealedProviderClosesCardAndDoesNotRestoreIt() throws {
        let (model, settings, defaults) = try fixture()
        model.receiveClaudeActivity(SessionActivity(sessions: [waiting("claude.123")]), entryID: "Claude-work")
        model.select("Claude-work")
        settings.remove("Claude-work")
        XCTAssertNil(model.selected)
        XCTAssertFalse(model.isExpanded)
        XCTAssertFalse(model.snapshots.contains { $0.id == "Claude-work" })
        XCTAssertFalse(model.allSnapshots.contains { $0.id == "Claude-work" })
        XCTAssertFalse(UsageSettings(defaults: defaults).value.rings.contains { $0.id == "Claude-work" })
        model.receiveClaudeActivity(SessionActivity(sessions: [waiting("claude.123")]), entryID: "Claude-work")
        XCTAssertFalse(model.dockActivity.waitingEntryIDs.contains("Claude-work"))
        model.isPointerOverIsland = { false }
        model.tickIdleWatchdog(now: .now)
        model.tickIdleWatchdog(now: .now.addingTimeInterval(100))
    }

    func testAutoHideReturnsToEdgeAfterConfiguredHoverDelay() throws {
        let (model, settings, _) = try fixture()
        let now = Date()
        XCTAssertTrue(model.isCompact)
        XCTAssertFalse(model.isDockHidden, "The existing compact appearance remains the default")
        settings.edit { $0.dock.autoHide = true; $0.collapseDelay = 0.75 }
        XCTAssertTrue(model.isDockHidden)
        XCTAssertEqual(model.dockInteractionSize.width, 8)
        XCTAssertLessThanOrEqual(model.dockInteractionSize.height, 140)

        model.setHovering(true, now: now)
        XCTAssertFalse(model.isDockHidden)
        model.setHovering(false, now: now)
        model.tickIdleWatchdog(now: now.addingTimeInterval(0.7))
        XCTAssertFalse(model.isCompact)
        model.tickIdleWatchdog(now: now.addingTimeInterval(0.8))
        XCTAssertTrue(model.isCompact)
        XCTAssertTrue(model.isDockHidden)
    }

    func testDraggingKeepsDockVisibleUntilDragEnds() throws {
        let (model, settings, _) = try fixture()
        settings.edit { $0.dock.autoHide = true }
        let now = Date()
        model.setHovering(true, now: now)
        model.setHovering(false, now: now)
        model.dockDragging = true
        model.tickIdleWatchdog(now: now.addingTimeInterval(100))
        XCTAssertFalse(model.isCompact)
        XCTAssertFalse(model.isDockHidden)
        model.dockDragging = false
        model.tickIdleWatchdog(now: now.addingTimeInterval(101))
        XCTAssertTrue(model.isCompact)
        XCTAssertTrue(model.isDockHidden)
    }

    func testIndependentZoomKeepsVisualAndNativeBoundsInSync() throws {
        let (model, settings, _) = try fixture()
        settings.edit { $0.dock.scale = 1; $0.dock.hoverScale = 1 }
        let rest = model.dockInteractionSize
        model.setHovering(true)
        let full = model.dockInteractionSize
        XCTAssertEqual(full.height, model.fullMetrics.islandHeight + model.dockFooterHeight, accuracy: 0.001)

        settings.edit { $0.dock.hoverScale = 0.8 }
        XCTAssertEqual(model.dockInteractionSize.width, full.width * 0.8, accuracy: 0.001)
        XCTAssertEqual(model.dockInteractionSize.height, full.height * 0.8, accuracy: 0.001)
        model.select("Codex")
        XCTAssertEqual(model.dockPanelSize(expanded: true).width, (full.width + 350) * 0.8, accuracy: 0.001)
        model.previewDockSize = .compact
        XCTAssertEqual(model.dockInteractionSize, rest)
        XCTAssertFalse(model.dockDetailVisible)
        settings.edit { $0.dock.scale = 0.7 }
        XCTAssertEqual(model.dockInteractionSize.width, rest.width * 0.7, accuracy: 0.001)
        XCTAssertEqual(model.dockInteractionSize.height, rest.height * 0.7, accuracy: 0.001)
        model.previewDockSize = nil
        XCTAssertTrue(model.dockDetailVisible)
        XCTAssertEqual(model.dockInteractionSize.width, full.width * 0.8, accuracy: 0.001)
    }

    func testSliderPreviewOverridesAutoHideWithoutEnteringRealHover() throws {
        let (model, settings, _) = try fixture()
        settings.edit { $0.dock.autoHide = true; $0.dock.scale = 1.4; $0.dock.hoverScale = 0.7 }
        XCTAssertTrue(model.isDockHidden)
        model.previewDockSize = .hover
        XCTAssertFalse(model.isDockHidden)
        model.setHovering(true)
        XCTAssertTrue(model.isCompact, "A settings preview must not synthesize a refresh-producing hover")
        XCTAssertEqual(model.dockZoom, 0.7, accuracy: 0.001)
        model.previewDockSize = .compact
        XCTAssertEqual(model.dockZoom, 1.4, accuracy: 0.001)
        model.previewDockSize = nil
        XCTAssertTrue(model.isDockHidden)
        XCTAssertEqual(model.dockInteractionSize.width, 8)
        settings.edit { $0.dock.autoHide = false; $0.alwaysShowNumbers = true }
        XCTAssertEqual(model.dockZoom, 0.7, accuracy: 0.001)
    }

    func testPanelContainsLargeRestingDockAndSmallHoverWithManyIcons() throws {
        let (model, settings, _) = try fixture()
        settings.edit {
            $0.rings = (0..<24).map { .init(id: "manual-\($0)", source: .custom, manualPercent: 25) }
            $0.dock.scale = 1.5; $0.dock.hoverScale = 0.5
        }
        XCTAssertEqual(model.snapshots.count, 24)
        let native = model.dockPanelSize(expanded: false)
        let rest = model.dockInteractionSize
        model.previewDockSize = .hover
        let full = model.dockInteractionSize
        XCTAssertGreaterThanOrEqual(native.width, max(rest.width, full.width))
        XCTAssertGreaterThanOrEqual(native.height, max(rest.height, full.height))
    }

    func testOpeningSessionWithoutKnownApplicationFallsBackToSessionsTab() throws {
        let (model, _, _) = try fixture()
        var calls = 0
        var tabWhenOpened: Int?
        model.onDashboard = { [weak model] in calls += 1; tabWhenOpened = model?.dashboardTab }
        XCTAssertEqual(model.dashboardTab, 0)
        // Nil process/application IDs guarantee this test cannot activate another app.
        let session = waiting()
        XCTAssertNil(session.processID)
        XCTAssertNil(session.applicationID)
        model.openSession(session)
        XCTAssertEqual(model.dashboardTab, 5)
        XCTAssertEqual(tabWhenOpened, 5)
        XCTAssertEqual(calls, 1)
    }
}
