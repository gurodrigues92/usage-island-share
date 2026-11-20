import Foundation
import Testing
@testable import UsageIsland

@MainActor
struct QuotaDisplayModeTests {
    private func isolated() -> (UserDefaults, String) {
        let name = "UsageIsland-QuotaDisplay-" + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }

    private func fixture(source: UsageSource, used: Double, now: Date) -> UsageSnapshot {
        var snapshot = UsageSnapshot(source: source, percentUsed: used, sessionPercent: nil,
            resetText: "", updatedAt: now, syncState: .live)
        snapshot.fidelity = .oficial
        snapshot.windows = [.init(id: "weekly", title: "Semanal", percent: used,
            resetsAt: now.addingTimeInterval(86400), duration: 7 * 86400)]
        snapshot.primaryWindowID = "weekly"
        return snapshot
    }

    @Test(arguments: [false, true])
    func legacyPreferencesPreserveGlobalModeAndCustomization(_ remaining: Bool) throws {
        var preferences = UsagePreferences()
        preferences.remaining = remaining
        preferences.rings = [.init(id: "SuperGrok", source: .grok, name: "Meu Grok", visible: false)]
        preferences.animationSpeed = 1.5
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        var rings = try #require(json["rings"] as? [[String: Any]])
        rings[0].removeValue(forKey: "remainingOverride")
        json["rings"] = rings

        let migrated = try JSONDecoder().decode(UsagePreferences.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(migrated.rings[0].remainingOverride == nil)
        #expect(migrated.showsRemaining(for: "SuperGrok") == remaining)
        #expect(migrated.rings[0].name == "Meu Grok")
        #expect(!migrated.rings[0].visible)
        #expect(migrated.animationSpeed == 1.5)
    }

    @Test func overridesPersistAcrossSettingsReloadAndCanReturnToGlobalMode() {
        let (defaults, name) = isolated()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let settings = UsageSettings(defaults: defaults, initial: [
            .init(id: "Codex", source: .codex), .init(id: "SuperGrok", source: .grok)
        ])
        settings.edit { $0.remaining = true }
        settings.editRing("Codex") { $0.remainingOverride = true }
        settings.editRing("SuperGrok") { $0.remainingOverride = false }

        let restored = UsageSettings(defaults: defaults)
        #expect(restored.issue == nil)
        #expect(restored.value.showsRemaining(for: "Codex"))
        #expect(!restored.value.showsRemaining(for: "SuperGrok"))
        restored.editRing("SuperGrok") { $0.remainingOverride = nil }
        let inherited = UsageSettings(defaults: defaults)
        #expect(inherited.value.rings.first { $0.id == "SuperGrok" }?.remainingOverride == nil)
        #expect(inherited.value.showsRemaining(for: "SuperGrok"))
    }

    @Test func mixedProviderDisplayDoesNotChangeOtherAccountsOrCollectedUsage() throws {
        let (defaults, name) = isolated()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let settings = UsageSettings(defaults: defaults, initial: [
            .init(id: "Codex", source: .codex), .init(id: "SuperGrok", source: .grok),
            .init(id: "OpenCode", source: .opencode)
        ])
        settings.editRing("Codex") { $0.remainingOverride = true }
        settings.editRing("SuperGrok") { $0.remainingOverride = false }
        let historyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = IslandModel(settings: settings, history: UsageHistory(url: historyURL),
            defaults: defaults, profiles: [])
        let now = Date()
        model.allSnapshots = [fixture(source: .codex, used: 8, now: now),
            fixture(source: .grok, used: 21, now: now), fixture(source: .opencode, used: 3, now: now)]

        #expect(model.snapshots.map(\.displayPercent) == ["92%", "21%", "3%"])
        settings.edit { $0.remaining = true }
        #expect(model.snapshots.map(\.displayPercent) == ["92%", "21%", "97%"])
        #expect(model.allSnapshots.map(\.percentUsed) == [8, 21, 3])
        #expect(model.allSnapshots.map { $0.windows[0].percent } == [8, 21, 3])
        #expect(settings.value.showsRemaining(for: "unconfigured-account"))

        settings.editRing("SuperGrok") { $0.remainingOverride = nil }
        #expect(try #require(model.snapshots.first { $0.id == "SuperGrok" }).displayPercent == "79%")
    }

    @Test func remainingPresentationKeepsHistoryInUsedPercent() async {
        let historyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: historyURL) }
        let history = UsageHistory(url: historyURL), now = Date()
        var snapshot = fixture(source: .codex, used: 8, now: now)
        snapshot.remaining = true
        #expect(snapshot.displayPercent == "92%")
        history.record(snapshot, retentionDays: 90, now: now)
        await history.flush()
        #expect(UsageHistory(url: historyURL).samples.first?.window.percent == 8)
    }

    @Test func grokRoundsOnlyTheMeasuredValueAcrossRingAndDashboard() {
        var snapshot = fixture(source: .grok, used: 20.95341, now: .now)
        #expect(snapshot.displayPercent == "21%")
        #expect(OverviewView.displayPercent(for: snapshot, remaining: false) == "21%")
        snapshot.remaining = true
        #expect(snapshot.displayPercent == "79%")
        #expect(snapshot.percentUsed == 20.95341)
        // An integer returned by the CLI must never be increased to match another UI.
        snapshot.windows[0].percent = 20
        snapshot.remaining = false
        #expect(snapshot.displayPercent == "20%")
        #expect(UsageValidation.display(nil, rounded: true) == "—")
        #expect(UsageValidation.display(.nan, rounded: true) == "—")
    }

    @Test func remainingPresentationKeepsAlertsOnUsedThresholds() {
        let (defaults, name) = isolated()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let engine = QuotaAlerts(defaults: defaults)
        var preferences = UsagePreferences()
        preferences.remaining = true
        preferences.notifications = true
        preferences.thresholds = [80]
        let now = Date()
        var before = fixture(source: .grok, used: 79, now: now)
        before.remaining = true
        #expect(engine.review(before, preferences: preferences, now: now).isEmpty)
        var after = before
        after.updatedAt = now.addingTimeInterval(1)
        after.percentUsed = 81
        after.windows[0].percent = 81
        #expect(after.displayPercent == "19%")
        let alerts = engine.review(after, preferences: preferences, now: after.updatedAt)
        #expect(alerts.count == 1)
        #expect(alerts.first?.kind == .threshold)
        #expect(engine.states["SuperGrok|weekly"]?.lastPercent == 81)
    }
}
