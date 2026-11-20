import AppKit
import Combine
import XCTest
@testable import UsageIsland

@MainActor
final class HoverRegressionTests: XCTestCase {
    private func model() throws -> IslandModel {
        let name = "UsageIsland-Hover-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return IslandModel(settings: UsageSettings(defaults: defaults, initial: UsageSettings.defaults(profiles: [.padrao])),
                           history: UsageHistory(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                           defaults: defaults, profiles: [.padrao])
    }

    func testRepeatedEnterDoesNotRestartLayoutAndQuickReturnCancelsCollapse() throws {
        let model = try model()
        let now = Date()
        var pointerHere = true
        model.isPointerOverIsland = { pointerHere }
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        model.setHovering(true, now: now)
        XCTAssertFalse(model.isCompact)
        let firstEnterChanges = changes
        for _ in 0..<100 { model.setHovering(true, now: now) }
        XCTAssertEqual(changes, firstEnterChanges, "Layout tracking must not republish the same hover")
        pointerHere = false
        model.setHovering(false, now: now)
        model.tickIdleWatchdog(now: now.addingTimeInterval(0.3))
        XCTAssertFalse(model.isCompact)
        pointerHere = true
        model.setHovering(true, now: now.addingTimeInterval(0.4))
        model.tickIdleWatchdog(now: now.addingTimeInterval(1))
        XCTAssertFalse(model.isCompact)
        pointerHere = false
        model.setHovering(false, now: now.addingTimeInterval(1))
        model.tickIdleWatchdog(now: now.addingTimeInterval(1.7))
        XCTAssertTrue(model.isCompact)
        withExtendedLifetime(subscription) {}
    }

    func testMissingExitRecoversAndNextEnterStillWorks() throws {
        let model = try model()
        let now = Date()
        model.isPointerOverIsland = { false }
        model.setHovering(true, now: now)
        model.tickIdleWatchdog(now: now)
        model.tickIdleWatchdog(now: now.addingTimeInterval(0.7))
        XCTAssertTrue(model.isCompact)
        model.setHovering(true, now: now.addingTimeInterval(1))
        XCTAssertFalse(model.isCompact)
        model.setHovering(false, now: now.addingTimeInterval(1))
        model.tickIdleWatchdog(now: now.addingTimeInterval(1.7))
    }

    func testOpenCardRetainsReadingTimeAndThenReturnsToCompact() throws {
        let model = try model()
        let now = Date()
        model.isPointerOverIsland = { false }
        model.setHovering(true, now: now)
        model.select("Claude")
        model.setHovering(false, now: now)
        model.tickIdleWatchdog(now: now.addingTimeInterval(1))
        XCTAssertTrue(model.isExpanded)
        XCTAssertFalse(model.isCompact)
        model.tickIdleWatchdog(now: now.addingTimeInterval(15.1))
        XCTAssertFalse(model.isExpanded)
        XCTAssertTrue(model.isCompact)
    }

    func testAnimationGeometryDoesNotRedrawWholeApp() throws {
        let model = try model()
        var modelChanges = 0
        var positionChanges = 0
        let parent = model.objectWillChange.sink { modelChanges += 1 }
        let positions = model.ringPositions.objectWillChange.sink { positionChanges += 1 }
        for frame in 0..<120 {
            model.ringPositions.update(["Claude": CGFloat(frame), "Codex": CGFloat(frame + 80)])
        }
        XCTAssertEqual(modelChanges, 0, "Moving an arrow must not invalidate all rings and settings tabs")
        XCTAssertEqual(positionChanges, 120)
        model.ringPositions.update(["Claude": 119.1, "Codex": 199.1])
        XCTAssertEqual(positionChanges, 120, "Subpixel layout noise should not trigger another update")
        model.ringPositions.update(["Claude": .infinity, "Codex": 200])
        XCTAssertNil(model.ringPositions.centers["Claude"])
        withExtendedLifetime((parent, positions)) {}
    }

    func testExistingPreferencesMigrateWithoutLosingCustomization() throws {
        let name = "UsageIsland-LegacyMotion-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        var old = UsagePreferences()
        old.rings = [.init(id: "Codex", source: .codex, name: "Minha conta", symbol: "brain", visible: false)]
        old.railWidth = 110; old.remaining = true
        let encoded = try JSONEncoder().encode(old)
        // The old v1 payload has no stored motion keys.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["storedAnimationSpeed"])
        XCTAssertNil(object["storedCollapseDelay"])
        XCTAssertNil(object["storedCardCollapseDelay"])
        defaults.set(encoded, forKey: UsageSettings.storageKey)
        let migrated = UsageSettings(defaults: defaults)
        XCTAssertNil(migrated.issue)
        XCTAssertEqual(migrated.value.rings, old.rings)
        XCTAssertEqual(migrated.value.railWidth, 110)
        XCTAssertTrue(migrated.value.remaining)
        XCTAssertEqual(migrated.value.animationSpeed, 1)
        XCTAssertEqual(migrated.value.collapseDelay, 0.65)
        XCTAssertEqual(migrated.value.cardCollapseDelay, 15)
        migrated.edit { $0.animationSpeed = 2; $0.collapseDelay = 3; $0.cardCollapseDelay = 8 }
        let restored = UsageSettings(defaults: defaults)
        XCTAssertEqual(restored.value.animationSpeed, 2)
        XCTAssertEqual(restored.value.collapseDelay, 3)
        XCTAssertEqual(restored.value.cardCollapseDelay, 8)
        XCTAssertEqual(restored.value.rings, old.rings)
    }

    func testConfiguredDelaysApplyImmediatelyToBarAndOpenCard() throws {
        let model = try model()
        let now = Date()
        model.isPointerOverIsland = { false }
        model.settings.edit { $0.collapseDelay = 3; $0.cardCollapseDelay = 5 }
        model.setHovering(true, now: now)
        model.setHovering(false, now: now)
        model.tickIdleWatchdog(now: now.addingTimeInterval(1))
        XCTAssertFalse(model.isCompact)
        model.settings.edit { $0.collapseDelay = 0.5 }
        model.tickIdleWatchdog(now: now.addingTimeInterval(1.1))
        XCTAssertTrue(model.isCompact)
        model.setHovering(true, now: now.addingTimeInterval(2))
        model.select("Claude")
        model.setHovering(false, now: now.addingTimeInterval(2))
        model.tickIdleWatchdog(now: now.addingTimeInterval(6.9))
        XCTAssertTrue(model.isExpanded)
        model.tickIdleWatchdog(now: now.addingTimeInterval(7.1))
        XCTAssertTrue(model.isCompact)
        XCTAssertFalse(model.isExpanded)
    }

    func testMotionLimitsKeepSlowAnimationsUnclippedAndRejectInvalidTimes() {
        var preferences = UsagePreferences()
        preferences.animationSpeed = 0.25
        XCTAssertEqual(preferences.hoverAnimationDuration, 1.12, accuracy: 0.001)
        XCTAssertGreaterThan(preferences.panelShrinkDelay, preferences.cardAnimationDuration)
        preferences.animationSpeed = 3
        XCTAssertLessThan(preferences.hoverAnimationDuration, 0.1)
        preferences.animationSpeed = .nan
        preferences.collapseDelay = -.infinity
        preferences.cardCollapseDelay = .infinity
        let safe = preferences.normalized()
        XCTAssertEqual(safe.animationSpeed, 1)
        XCTAssertEqual(safe.collapseDelay, 0.65)
        XCTAssertEqual(safe.cardCollapseDelay, 15)
        preferences.animationSpeed = 0; preferences.collapseDelay = -5; preferences.cardCollapseDelay = 900
        let bounded = preferences.normalized()
        XCTAssertEqual(bounded.animationSpeed, 0.25)
        XCTAssertEqual(bounded.collapseDelay, 0)
        XCTAssertEqual(bounded.cardCollapseDelay, 60)
    }
}
