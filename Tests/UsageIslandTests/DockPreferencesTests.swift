import Foundation
import Testing
@testable import UsageIsland

@MainActor
struct DockPreferencesTests {
    @Test func legacySettingsKeepExistingLayoutAndProviderModes() throws {
        var previous = UsagePreferences()
        previous.rings = [.init(id: "Codex", source: .codex, name: "Meu Codex", remainingOverride: true)]
        previous.verticalPosition = 0.27
        previous.edge = .left
        previous.railWidth = 110
        previous.animationSpeed = 1.4
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(previous)) as? [String: Any])
        encoded.removeValue(forKey: "storedDock")

        let restored = try JSONDecoder().decode(UsagePreferences.self, from: JSONSerialization.data(withJSONObject: encoded)).normalized()
        #expect(restored.dock == DockPreferences())
        #expect(!restored.dock.autoHide)
        #expect(restored.dock.dragHandle)
        #expect(restored.rings == previous.rings)
        #expect(restored.verticalPosition == 0.27)
        #expect(restored.edge == .left)
        #expect(restored.railWidth == 110)
        #expect(restored.animationSpeed == 1.4)
    }

    @Test func oldDockScaleSeedsBothModesAndTheyCanBeEditedIndependently() throws {
        let domain = "UsageIsland-DockZoom-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var legacy = UsagePreferences()
        legacy.dock.scale = 1.15
        legacy.rings = [.init(id: "Codex", source: .codex, remainingOverride: true)]
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        var dock = try #require(json["storedDock"] as? [String: Any])
        dock.removeValue(forKey: "storedHoverScale")
        json["storedDock"] = dock
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: UsageSettings.storageKey)
        let settings = UsageSettings(defaults: defaults)
        #expect(settings.value.dock.hoverScale == 1.15)
        settings.edit { $0.dock.scale = 0.91 }
        #expect(settings.value.dock.hoverScale == 1.15)
        settings.edit { $0.dock.hoverScale = 0.78 }
        let restored = UsageSettings(defaults: defaults).value
        #expect(restored.dock.hoverScale == 0.78)
        #expect(restored.dock.scale == 0.91)
        #expect(restored.rings == legacy.rings)
    }

    @Test func dockOptionsPersistWithoutChangingQuotaPreferences() throws {
        let domain = "UsageIsland-DockPreferences-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let settings = UsageSettings(defaults: defaults, initial: [.init(id: "Codex", source: .codex, remainingOverride: true)])
        settings.edit {
            $0.dock.enabled = false
            $0.dock.autoHide = true
            $0.dock.edgeHint = false
            $0.dock.dragHandle = false
            $0.dock.scale = 0.7
            $0.dock.presentation = .appWindows
            $0.dock.showCompleted = false
            $0.dock.showNewActivity = false
            $0.verticalPosition = 0.8
        }
        let restored = UsageSettings(defaults: defaults)
        #expect(restored.issue == nil)
        #expect(restored.value.dock == settings.value.dock)
        #expect(restored.value.verticalPosition == 0.8)
        #expect(restored.value.showsRemaining(for: "Codex"))
        #expect(restored.value.thresholds == [80, 90, 100])
        #expect(!restored.value.notifications)
    }

    @Test func dockScaleNormalizesWithoutChangingBehaviorChoices() {
        for (input, expected) in [(-1.0, 0.5), (0.7, 0.7), (2.0, 1.5), (Double.infinity, 1.0), (Double.nan, 1.0)] {
            var preferences = UsagePreferences()
            preferences.dock.scale = input
            preferences.dock.autoHide = true
            preferences.dock.presentation = .appWindows
            preferences.dock.edgeHint = false
            let normalized = preferences.normalized()
            #expect(normalized.dock.scale == expected)
            #expect(normalized.dock.autoHide)
            #expect(normalized.dock.presentation == .appWindows)
            #expect(!normalized.dock.edgeHint)
        }
    }
}
