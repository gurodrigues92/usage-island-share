import AppKit
import Foundation
import Testing
@testable import UsageIsland

@MainActor
struct PowerupsTests {
    private func isolated() -> (UserDefaults, String) {
        let name = "UsageIsland-Powerups-" + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }
    private func fixture(percent: Double, date: Date, reset: Date, id: String = "Codex") -> UsageSnapshot {
        var snapshot = UsageSnapshot(source: .codex, percentUsed: percent, sessionPercent: nil, resetText: "", updatedAt: date, syncState: .live)
        snapshot.entryID = id; snapshot.fidelity = .oficial
        snapshot.windows = [.init(id: "weekly", title: "Semanal", percent: percent, resetsAt: reset, duration: 7 * 86400)]
        snapshot.primaryWindowID = "weekly"
        return snapshot
    }
    private func temp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("UsageIsland-Test-" + UUID().uuidString) }

    @Test func settingsPersistOrderVisibilityPauseAndNames() {
        let (defaults, name) = isolated(); defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let settings = UsageSettings(defaults: defaults, initial: UsageSettings.defaults(profiles: [.padrao]))
        settings.move("Codex", by: -1)
        settings.editRing("SuperGrok") { $0.visible = false; $0.enabled = false; $0.name = "Minha conta"; $0.symbol = "cpu" }
        let restored = UsageSettings(defaults: defaults)
        #expect(restored.value.rings.first?.id == "Codex")
        #expect(restored.value.rings.first { $0.id == "SuperGrok" }?.visible == false)
        #expect(restored.value.rings.first { $0.id == "SuperGrok" }?.enabled == false)
        #expect(restored.value.rings.first { $0.id == "SuperGrok" }?.name == "Minha conta")
    }

    @Test func removeAndAddDoNotDuplicateOrSilentlyRestoreIcons() {
        let (defaults, name) = isolated(); defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let settings = UsageSettings(defaults: defaults, initial: UsageSettings.defaults(profiles: [.padrao]))
        settings.remove("Codex")
        #expect(!UsageSettings(defaults: defaults, initial: UsageSettings.defaults(profiles: [.padrao])).value.rings.contains { $0.id == "Codex" })
        settings.add(.init(id: "Codex", source: .codex)); settings.add(.init(id: "Codex", source: .codex))
        #expect(settings.value.rings.filter { $0.id == "Codex" }.count == 1)
        settings.move("Codex", before: "Claude")
        #expect(settings.value.rings.first?.id == "Codex")
    }

    @Test func hiddenSourceKeepsDataAndEmptyBarIsSafe() {
        let (defaults, name) = isolated(); defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let settings = UsageSettings(defaults: defaults, initial: UsageSettings.defaults(profiles: [.padrao]))
        let model = IslandModel(settings: settings, history: UsageHistory(url: temp()), defaults: defaults, profiles: [.padrao])
        model.allSnapshots[1] = fixture(percent: 35, date: .now, reset: .now.addingTimeInterval(86400))
        settings.editRing("Codex") { $0.visible = false }
        #expect(!model.snapshots.contains { $0.id == "Codex" })
        #expect(model.allSnapshots.first { $0.id == "Codex" }?.percentUsed == 35)
        #expect(model.isEnabled("Codex"))
        settings.edit { for index in $0.rings.indices { $0.rings[index].visible = false } }
        #expect(model.snapshots.isEmpty)
        #expect(model.metrics.islandHeight > 0)
        #expect(model.snapshot(id: "missing").source == .custom)
    }

    @Test func invalidPreferencesAreNormalizedAndCorruptionIsPreserved() {
        let (defaults, name) = isolated(); defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        defaults.set(Data("broken".utf8), forKey: UsageSettings.storageKey)
        let settings = UsageSettings(defaults: defaults)
        #expect(settings.issue != nil)
        #expect(defaults.data(forKey: UsageSettings.storageKey + ".unreadable") != nil)
        settings.edit { $0.railWidth = .infinity; $0.compactOpacity = -3; $0.thresholds = [0, 80, 80, 101]; $0.retentionDays = -1 }
        #expect(settings.value.railWidth == 92)
        #expect(settings.value.compactOpacity == 0.25)
        #expect(settings.value.thresholds == [80])
        #expect(settings.value.retentionDays == 90)
    }

    @Test func windowSelectionAndRemainingKeepAllLimits() {
        var snapshot = fixture(percent: 30, date: .now, reset: .now.addingTimeInterval(86400))
        snapshot.windows.append(.init(id: "short", title: "5h", percent: 90))
        snapshot.preferredWindowID = "short"; snapshot.remaining = true
        #expect(snapshot.displayPercent == "10%")
        #expect(snapshot.percentUsed == 30)
        #expect(snapshot.windows.count == 2)
        snapshot.preferredWindowID = "missing"
        #expect(snapshot.selectedWindow?.id == "weekly")
    }

    @Test func manualIndicatorsGetTimestampAndNeverBecomeOfficial() {
        let (defaults, name) = isolated(); defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let settings = UsageSettings(defaults: defaults)
        settings.add(.init(id: "manual", source: .custom, name: "Minha IA"))
        let model = IslandModel(settings: settings, history: UsageHistory(url: temp()), defaults: defaults, profiles: [])
        settings.editRing("manual") { $0.manualPercent = 42 }
        #expect(model.snapshots.first?.displayPercent == "42%")
        #expect(model.snapshots.first?.fidelity == .manual)
        #expect(settings.value.rings.first?.manualUpdatedAt != nil)
    }

    @Test func historyPersistsAndDoesNotAcceptFailedOrManualData() async throws {
        let url = temp(); defer { try? FileManager.default.removeItem(at: url) }
        let history = UsageHistory(url: url), now = Date()
        let good = fixture(percent: 40, date: now, reset: now.addingTimeInterval(86400))
        history.record(good, retentionDays: 90, now: now)
        var failed = good; failed.syncState = .failed; failed.updatedAt = now.addingTimeInterval(400)
        #expect(history.record(failed, retentionDays: 90, now: failed.updatedAt).isEmpty)
        failed.syncState = .live; failed.fidelity = .manual
        #expect(history.record(failed, retentionDays: 90, now: failed.updatedAt).isEmpty)
        await history.flush()
        #expect(UsageHistory(url: url).samples.count == 1)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func reductionStartsNewEpochEvenInSameBucket() {
        let history = UsageHistory(url: temp()), now = Date(), reset = Date().addingTimeInterval(86400)
        history.record(fixture(percent: 80, date: now, reset: reset), retentionDays: 90, now: now)
        history.record(fixture(percent: 10, date: now.addingTimeInterval(1), reset: reset), retentionDays: 90, now: now.addingTimeInterval(1))
        #expect(history.samples.count == 2)
        #expect(history.samples.last?.epoch == 1)
        #expect(history.forecast(for: fixture(percent: 10, date: now.addingTimeInterval(1), reset: reset), now: now.addingTimeInterval(1)) == nil)
    }

    @Test func historyRejectsOutOfOrderAndSeparatesAccounts() {
        let history = UsageHistory(url: temp()), now = Date(), reset = Date().addingTimeInterval(86400)
        history.record(fixture(percent: 20, date: now, reset: reset, id: "A"), retentionDays: 90, now: now)
        history.record(fixture(percent: 50, date: now.addingTimeInterval(-1), reset: reset, id: "A"), retentionDays: 90, now: now)
        history.record(fixture(percent: 70, date: now, reset: reset, id: "B"), retentionDays: 90, now: now)
        #expect(history.samples.count == 2)
        #expect(history.samples.first { $0.entryID == "A" }?.window.percent == 20)
    }

    @Test func corruptHistoryNeverGetsOverwritten() async throws {
        let url = temp(); defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("not json".utf8); try original.write(to: url)
        let history = UsageHistory(url: url)
        history.record(fixture(percent: 20, date: .now, reset: .now.addingTimeInterval(86400)), retentionDays: 90)
        await history.flush()
        #expect(history.issue != nil)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func historyRetentionAndCSVAreExplicit() {
        let history = UsageHistory(url: temp()), now = Date()
        history.record(fixture(percent: 20, date: now, reset: now.addingTimeInterval(86400), id: "Account, with comma"), retentionDays: 90, now: now)
        #expect(history.exportCSV().contains("\"Account, with comma\""))
        history.trim(retentionDays: 7, now: now.addingTimeInterval(8 * 86400))
        #expect(history.samples.isEmpty)
    }

    private func sample(_ percent: Double, _ time: Date, _ reset: Date, epoch: Int = 0, id: String = "A") -> QuotaSample {
        .init(entryID: id, source: "Codex", window: .init(id: "short", title: "5h", percent: percent, resetsAt: reset, duration: 18000), capturedAt: time, epoch: epoch)
    }
    @Test func forecastNeedsEvidenceAndShowsRiskWithoutChangingQuota() throws {
        let now = Date(), reset = now.addingTimeInterval(10800)
        let points = [sample(20, now.addingTimeInterval(-1800), reset), sample(30, now.addingTimeInterval(-1200), reset), sample(40, now.addingTimeInterval(-600), reset), sample(50, now, reset)]
        let forecast = try #require(QuotaForecast.calculate(samples: points, now: now, staleAfter: 180))
        #expect(forecast.atRisk)
        #expect(forecast.confidence == .medium)
        #expect(abs(forecast.pointsPerHour - 60) < 0.01)
        #expect(points.last?.window.percent == 50)
        #expect(QuotaForecast.calculate(samples: Array(points.suffix(2)), now: now, staleAfter: 180) == nil)
        #expect(QuotaForecast.calculate(samples: points, now: now.addingTimeInterval(181), staleAfter: 180) == nil)
    }

    @Test func forecastDoesNotMixNewGrantsAccountsOrExpiredWindows() {
        let now = Date(), reset = now.addingTimeInterval(10800)
        let points = [sample(80, now.addingTimeInterval(-1800), reset), sample(90, now.addingTimeInterval(-1200), reset), sample(10, now, reset, epoch: 1)]
        #expect(QuotaForecast.calculate(samples: points, now: now, staleAfter: 180) == nil)
        let cross = [sample(10, now.addingTimeInterval(-1800), reset, id: "A"), sample(80, now.addingTimeInterval(-1200), reset, id: "A"), sample(10, now, reset, id: "B")]
        #expect(QuotaForecast.calculate(samples: cross, now: now, staleAfter: 180) == nil)
        #expect(QuotaForecast.calculate(samples: points, now: reset, staleAfter: 180) == nil)
    }

    @Test func alertsFireOnceAcrossRestartAndRearmAfterReset() {
        let (defaults, name) = isolated(); defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let engine = QuotaAlerts(defaults: defaults); var preferences = UsagePreferences(); preferences.notifications = true
        let now = Date(), reset = now.addingTimeInterval(86400)
        #expect(engine.review(fixture(percent: 79, date: now, reset: reset), preferences: preferences, now: now).isEmpty)
        let next = now.addingTimeInterval(1)
        #expect(engine.review(fixture(percent: 91, date: next, reset: reset), preferences: preferences, now: next).count == 2)
        #expect(QuotaAlerts(defaults: defaults).review(fixture(percent: 92, date: next.addingTimeInterval(1), reset: reset), preferences: preferences, now: next.addingTimeInterval(1)).isEmpty)
        let start = next.addingTimeInterval(2), newReset = reset.addingTimeInterval(86400)
        _ = engine.review(fixture(percent: 1, date: start, reset: newReset), preferences: preferences, now: start)
        #expect(engine.review(fixture(percent: 81, date: start.addingTimeInterval(1), reset: newReset), preferences: preferences, now: start.addingTimeInterval(1)).count == 1)
    }

    @Test func alertsRejectFailureManualAndStaleAndConfirmRecovery() {
        let (defaults, name) = isolated(); defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let engine = QuotaAlerts(defaults: defaults); var preferences = UsagePreferences(); preferences.notifications = true
        let now = Date(), reset = now.addingTimeInterval(86400)
        _ = engine.review(fixture(percent: 100, date: now, reset: reset), preferences: preferences, now: now)
        var bad = fixture(percent: 1, date: now.addingTimeInterval(1), reset: reset); bad.syncState = .failed
        #expect(engine.review(bad, preferences: preferences, now: bad.updatedAt).isEmpty)
        bad.syncState = .live; bad.fidelity = .manual
        #expect(engine.review(bad, preferences: preferences, now: bad.updatedAt).isEmpty)
        bad.fidelity = .oficial
        #expect(engine.review(bad, preferences: preferences, now: bad.updatedAt.addingTimeInterval(200)).isEmpty)
        #expect(engine.review(bad, preferences: preferences, now: bad.updatedAt).first?.kind == .recovered)
    }

    @Test func alertsAreAccountSpecificAndSilentOnFirstReading() {
        let (defaults, name) = isolated(); defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let engine = QuotaAlerts(defaults: defaults); var preferences = UsagePreferences(); preferences.notifications = true
        let now = Date(), reset = now.addingTimeInterval(86400)
        #expect(engine.review(fixture(percent: 90, date: now, reset: reset, id: "already-high"), preferences: preferences, now: now).isEmpty)
        for id in ["A", "B"] {
            _ = engine.review(fixture(percent: 70, date: now, reset: reset, id: id), preferences: preferences, now: now)
            #expect(engine.review(fixture(percent: 81, date: now.addingTimeInterval(1), reset: reset, id: id), preferences: preferences, now: now.addingTimeInterval(1)).count == 1)
        }
    }

    @Test func quietHoursAcrossMidnightDoNotSilenceWholeDay() {
        var preferences = UsagePreferences(); preferences.quietHours = true; preferences.quietFrom = 22; preferences.quietUntil = 8
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(preferences.isQuiet(at: ISO8601DateFormatter().date(from: "2026-10-14T23:00:00Z")!, calendar: calendar))
        #expect(preferences.isQuiet(at: ISO8601DateFormatter().date(from: "2026-10-14T07:00:00Z")!, calendar: calendar))
        #expect(!preferences.isQuiet(at: ISO8601DateFormatter().date(from: "2026-10-14T12:00:00Z")!, calendar: calendar))
    }

    @Test func backoffPersistsAndIsAccountSpecific() async {
        let (_, name) = isolated(); defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let now = Date(), backoff = HTTPBackoff(suiteName: name)
        await backoff.failed("A", retryAfter: "600", now: now)
        #expect(await backoff.waiting("B", now: now) == nil)
        #expect(await HTTPBackoff(suiteName: name).waiting("A", now: now.addingTimeInterval(599)) != nil)
        #expect(await backoff.waiting("A", now: now.addingTimeInterval(601)) == nil)
    }

    @Test func availableProviderUsesMostRestrictiveWindow() {
        let (defaults, name) = isolated(); defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let settings = UsageSettings(defaults: defaults, initial: [.init(id: "A", source: .codex), .init(id: "B", source: .codex)])
        let model = IslandModel(settings: settings, history: UsageHistory(url: temp()), defaults: defaults, profiles: [])
        var a = fixture(percent: 10, date: .now, reset: .now.addingTimeInterval(86400), id: "A")
        a.windows.append(.init(id: "short", title: "Short", percent: 100))
        model.allSnapshots = [a, fixture(percent: 50, date: .now, reset: .now.addingTimeInterval(86400), id: "B")]
        #expect(model.mostRoom?.id == "B")
        model.allSnapshots[1].markFailed("offline")
        #expect(model.mostRoom == nil)
    }

    @Test func diagnosticsOmitSecretsNamesAndPaths() throws {
        let (defaults, name) = isolated(); defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let settings = UsageSettings(defaults: defaults, initial: [.init(id: "secret@example.com", source: .codex, name: "Sensitive account", directory: "/private/path")])
        let model = IslandModel(settings: settings, history: UsageHistory(url: temp()), defaults: defaults, profiles: [])
        model.allSnapshots[0].failureReason = "Bearer SECRET /private/path"
        let text = String(decoding: try model.diagnosticData(), as: UTF8.self)
        #expect(!text.contains("SECRET")); #expect(!text.contains("example.com")); #expect(!text.contains("/private/path")); #expect(!text.contains("Sensitive"))
    }

    @Test func codexActivityNeedsTurnCompletionNotChildItemCompletion() throws {
        let now = Date()
        let working = Data(([#"{"type":"event_msg","payload":{"type":"task_started"}}"#,
                             #"{"type":"event_msg","payload":{"type":"item_completed"}}"#].joined(separator: "\n")).utf8)
        #expect(ActivityFiles.codexSession(working, id: "X", modifiedAt: now, now: now)?.state == .busy)
        let ended = working + Data("\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}".utf8)
        #expect(ActivityFiles.codexSession(ended, id: "X", modifiedAt: now, now: now)?.completionConfirmed == true)
        let aborted = working + Data("\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\"}}".utf8)
        #expect(ActivityFiles.codexSession(aborted, id: "X", modifiedAt: now, now: now) == nil)
    }

    @Test func activityFallbackIsExplicitAndExpires() {
        let now = Date(), data = Data("{}".utf8)
        #expect(ActivityFiles.codexSession(data, id: "X", modifiedAt: now, now: now)?.isHeuristic == true)
        #expect(ActivityFiles.codexSession(data, id: "X", modifiedAt: now, now: now.addingTimeInterval(121)) == nil)
    }

    @Test func openRouterWithoutLimitDoesNotInventPercent() throws {
        let value = try #require(OpenRouterUsageReader.parse(Data(#"{"data":{"usage":12.5,"limit":null}}"#.utf8)))
        #expect(value.window == nil)
        #expect(value.balance.contains("12.50"))
        #expect(OpenRouterUsageReader.parse(Data(#"{"data":{"usage":true,"limit":100}}"#.utf8)) == nil)
    }

    @Test func openRouterBudgetHasRealResetAndSignalsOverspend() throws {
        let value = try #require(OpenRouterUsageReader.parse(Data(#"{"data":{"effective_budget":{"spend_usd":60,"limit_usd":50,"reset_interval":"weekly","resets_at":"2026-10-20T00:00:00Z"}}}"#.utf8)))
        #expect(value.window?.percent == 100); #expect(value.window?.blocked == true)
        #expect(value.window?.resetsAt != nil)
    }

    @Test func pricesKeepUnknownModelsUnpricedAndCacheDisjoint() {
        var row = TokenUsageRow(id: "A", provider: "Claude", project: "P", model: "claude-sonnet-4-6", day: "2026-10-14",
                               input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 0, cacheWrite1h: 0, calls: 1)
        #expect(abs((row.apiEquivalent(prices: UsagePreferences().prices) ?? 0) - 18.3) < 0.001)
        row.model = "unknown"
        #expect(row.apiEquivalent(prices: UsagePreferences().prices) == nil)
        #expect(row.tokens == 3_000_000)
    }

    @Test func placementAndLargeBarStayInsideScreen() {
        let screen = NSRect(x: 100, y: 50, width: 1000, height: 800)
        let left = IslandPlacement.frame(size: NSSize(width: 400, height: 5000), visible: screen, edge: .left, position: 1)
        #expect(left.minX == screen.minX); #expect(left.minY == screen.minY); #expect(left.height <= screen.height)
        let right = IslandPlacement.frame(size: NSSize(width: 90, height: 400), visible: screen, edge: .right, position: 0.5)
        #expect(right.maxX == screen.maxX); #expect(right.midY == screen.midY)
        #expect(IslandMetrics(railWidth: 40, showsPercent: true, ringCount: 24, heightLimit: 600).islandHeight == 600)
    }

    @Test func malformedDatesNeverReachIntegerFormatting() {
        #expect(!QuotaWindow(id: "bad", title: "", percent: 20, resetsAt: Date(timeIntervalSince1970: 1e300)).valid)
        #expect(!QuotaWindow(id: "bad", title: "", percent: .infinity).valid)
        #expect(CodexUsageReader.parse(result: ["rateLimits": ["primary": ["usedPercent": 20, "resetsAt": 1e300]]]) == nil)
        #expect(CodexUsageReader.parse(result: ["rateLimits": ["primary": ["usedPercent": 20, "resetsAt": true]]]) == nil)
    }

    @Test func statusFeedHasIndependentFreshnessAndRejectsUnknownShape() throws {
        let health = try #require(ServiceStatus.parse(Data(#"{"status":{"indicator":"major","description":"irrelevant"}}"#.utf8)))
        #expect(health.incident)
        #expect(ServiceStatus.parse(Data(#"{"status":{"indicator":"unknown"}}"#.utf8)) == nil)
    }
}

extension PowerupsTests {
    @Test func overviewRemainingIncludesManualAndCacheReadings() {
        for source in [UsageSource.custom, .claude] {
            let snapshot = UsageSnapshot(source: source, percentUsed: 8, sessionPercent: nil,
                                         resetText: "", updatedAt: .now, syncState: .manual)
            #expect(OverviewView.displayPercent(for: snapshot, remaining: false) == "8%")
            #expect(OverviewView.displayPercent(for: snapshot, remaining: true) == "92%")
        }
    }

    @Test func historySelectionKeepsWindowsAndResetSegmentsWithoutRepeatedSearches() {
        let now = Date(timeIntervalSince1970: 1_800_000_000), reset = Date(timeIntervalSince1970: 1_800_100_000)
        var records = [sample(10, now.addingTimeInterval(-8000), reset, id: "A"),
                       sample(20, now.addingTimeInterval(-7900), reset, id: "A"),
                       sample(30, now.addingTimeInterval(-1000), reset, id: "A"),
                       sample(5, now.addingTimeInterval(-900), reset.addingTimeInterval(86400), id: "A"),
                       sample(15, now.addingTimeInterval(-800), reset, id: "B")]
        var weekly = records[3]; weekly.window.id = "weekly"; weekly.window.title = "Semanal"
        records.append(weekly)
        records.sort { $0.capturedAt < $1.capturedAt }
        let chosen = QuotaHistorySelection(entryIDs: ["Empty", "A", "B"], samples: records,
                                           preferredEntryID: "A", preferredWindowID: "short", days: 1, now: now)
        #expect(chosen.entryID == "A")
        #expect(chosen.windowID == "short")
        #expect(Set(chosen.windows.map(\.id)) == Set(["short", "weekly"]))
        #expect(chosen.points.map(\.segment) == ["segment-0", "segment-0", "segment-1", "segment-2"])
        let fallback = QuotaHistorySelection(entryIDs: ["Empty", "A", "B"], samples: records,
                                             preferredEntryID: "Removed", preferredWindowID: "Removed", days: 1, now: now)
        #expect(fallback.entryID == "A")
        #expect(fallback.windows.contains { $0.id == fallback.windowID })
        let empty = QuotaHistorySelection(entryIDs: [], samples: records,
                                         preferredEntryID: "", preferredWindowID: "", days: 1, now: now)
        #expect(empty.entryID.isEmpty && empty.windows.isEmpty && empty.points.isEmpty)
    }

    @Test func historySelectionScalesToArchiveLimit() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let records = (0..<100_000).map { index in
            QuotaSample(entryID: "A\(index % 20)", source: "Codex",
                        window: QuotaWindow(id: "W\((index / 20) % 5)", title: "Janela", percent: Double(index % 100),
                                            resetsAt: now.addingTimeInterval(86400)),
                        capturedAt: now.addingTimeInterval(Double(index - 100_000)), epoch: 0)
        }
        let start = ProcessInfo.processInfo.systemUptime
        let chosen = QuotaHistorySelection(entryIDs: (0..<20).map { "A\($0)" }, samples: records,
                                           preferredEntryID: "A7", preferredWindowID: "W3", days: 7, now: now)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        #expect(chosen.points.count == 1000)
        #expect(chosen.windows.count == 5)
        #expect(chosen.points.allSatisfy { $0.sample.entryID == "A7" && $0.sample.window.id == "W3" })
        #expect(elapsed < 2, "100k observations should resolve without nested archive scans (\(elapsed)s)")
    }

    @Test func forecastSeparatesSafeAndRiskyWindowsAndRejectsPausedOrChangedCycles() throws {
        let url = temp(); defer { try? FileManager.default.removeItem(at: url) }
        let history = UsageHistory(url: url), now = Date(), reset = Date().addingTimeInterval(86400)
        var latest = fixture(percent: 95, date: now, reset: reset)
        for index in 0..<4 {
            var snapshot = fixture(percent: 80 + Double(index) * 5, date: now.addingTimeInterval(Double(index - 3) * 600), reset: reset)
            snapshot.windows.append(.init(id: "short", title: "5h", percent: 10 + Double(index), resetsAt: now.addingTimeInterval(1800), duration: 18000))
            snapshot.primaryWindowID = "short"
            history.record(snapshot, retentionDays: 90, now: snapshot.updatedAt)
            latest = snapshot
        }
        #expect(try #require(history.forecast(for: latest, windowID: "short", now: now)).atRisk == false)
        #expect(try #require(history.forecast(for: latest, windowID: "weekly", now: now)).atRisk)
        #expect(history.forecast(for: latest, windowID: "weekly", now: now.addingTimeInterval(181)) == nil)
        latest.paused = true
        #expect(history.forecast(for: latest, windowID: "weekly", now: now) == nil)
        latest.paused = false
        latest.windows[0].resetsAt = reset.addingTimeInterval(86400)
        #expect(history.forecast(for: latest, windowID: "weekly", now: now) == nil)
    }
}
