import Foundation
import Testing
@testable import UsageIsland

struct AuditRegressionTests {
    @Test func codexKeepsOwnSecondaryWindow() throws {
        let quota: [String: Any] = ["limitId": "codex", "primary": ["usedPercent": 20, "windowDurationMins": 300],
                                  "secondary": ["usedPercent": 99, "windowDurationMins": 10080]]
        let value = try #require(CodexUsageReader.parse(result: ["rateLimits": quota, "rateLimitsByLimitId": ["codex": quota]]))
        #expect(value.percentUsed == 20)
        #expect(value.limitLabel == "Janela de 5h")
        #expect(value.extras.contains { $0.percent == 99 && $0.titulo == "Semanal" })
    }

    @Test func codexSecondaryIsKeptWithoutMultiBucketView() throws {
        let value = try #require(CodexUsageReader.parse(result: ["rateLimits": ["primary": ["usedPercent": 10], "secondary": ["usedPercent": 0]]]))
        #expect(value.extras.count == 1)
        #expect(value.extras[0].percent == 0)
    }

    @Test func codexRejectsMalformedSecondary() {
        #expect(CodexUsageReader.parse(result: ["rateLimits": ["primary": ["usedPercent": 10], "secondary": ["usedPercent": true]]]) == nil)
    }

    @Test func credentialsAreIsolatedEvenWhenTimestampsMatch() async throws {
        let cache = ClaudeOAuthReader.CredentialCache(modificationDate: { _ in nil })
        let a = ClaudeOAuthReader.Credentials(accessToken: "fixture-A", expiresAt: .distantFuture, plan: nil)
        let b = ClaudeOAuthReader.Credentials(accessToken: "fixture-B", expiresAt: .distantFuture, plan: nil)
        _ = try await cache.valor(service: "account-A") { _ in a }
        let value = try await cache.valor(service: "account-B") { _ in b }
        #expect(value.accessToken == b.accessToken)
        await cache.esquecer(service: "account-A")
        let stillB = try await cache.valor(service: "account-B") { _ in a }
        #expect(stillB.accessToken == b.accessToken)
    }

    @Test func claudeBackoffIsPerAccount() async {
        let suite = "usage-island-tests-" + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let a = ClaudeOAuthReader.Backoff(service: "A", suiteName: suite)
        let b = ClaudeOAuthReader.Backoff(service: "B", suiteName: suite)
        _ = await a.punir(sugestao: nil)
        #expect(await a.esperando() != nil)
        #expect(await b.esperando() == nil)
        _ = await b.punir(sugestao: nil)
        await a.perdoar()
        #expect(await b.esperando() != nil)
    }

    @Test func claudeModelsHaveUniqueIdentityAndRemainVisible() throws {
        let data = Data(#"{"limits":[{"kind":"weekly_scoped","percent":10,"scope":{"model":{"display_name":"Opus"}}},{"kind":"weekly_scoped","percent":90,"scope":{"model":{"display_name":"Sonnet"}}}]}"#.utf8)
        let windows = try ClaudeOAuthReader.decodeUsage(data)
        #expect(Set(windows.map(\.id)).count == 2)
        let value = ClaudeOAuthReader.Reading(windows: windows, plan: nil, updatedAt: .now)
        #expect(value.geral?.percent == 90)
        #expect(value.otherWeeklies.count == 1)
        #expect(value.otherWeeklies.first?.percent == 10)
    }

    @Test(arguments: [#"{"limits":[{"kind":"weekly_all","percent":1e300}]}"#,
                      #"{"seven_day":{"utilization":-1}}"#,
                      #"{"five_hour":{"utilization":101}}"#, "{}"])
    func claudeRejectsInvalidUsage(_ json: String) {
        #expect(throws: (any Error).self) { try ClaudeOAuthReader.decodeUsage(Data(json.utf8)) }
    }

    @Test func transientClaudeFailureRetriesWithoutFifteenMinuteDelay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var schedule = ClaudeRefreshSchedule()
        #expect({ schedule.reserve(service: "A", revision: nil, now: now) }())
        schedule.failed(service: "A", now: now)
        #expect({ !schedule.reserve(service: "A", revision: nil, now: now.addingTimeInterval(59)) }())
        #expect({ schedule.reserve(service: "A", revision: nil, now: now.addingTimeInterval(61)) }())
        schedule.succeeded(service: "A", now: now.addingTimeInterval(61))
        #expect({ !schedule.reserve(service: "A", revision: nil, now: now.addingTimeInterval(120)) }())
        #expect({ schedule.reserve(service: "B", revision: nil, now: now.addingTimeInterval(120)) }())
    }

    @Test func renewedClaudeCredentialWakesItsAccount() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var schedule = ClaudeRefreshSchedule()
        #expect({ schedule.reserve(service: "A", revision: now, now: now) }())
        schedule.succeeded(service: "A", now: now)
        #expect({ !schedule.reserve(service: "A", revision: now, now: now.addingTimeInterval(1)) }())
        #expect({ schedule.reserve(service: "A", revision: now.addingTimeInterval(1), now: now.addingTimeInterval(1)) }())
    }

    @Test func claudeRetryAfterIsHonored() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var schedule = ClaudeRefreshSchedule()
        _ = schedule.reserve(service: "A", revision: nil, now: now)
        schedule.failed(service: "A", notBefore: now.addingTimeInterval(600), now: now)
        #expect({ !schedule.reserve(service: "A", revision: nil, now: now.addingTimeInterval(599)) }())
        #expect({ schedule.reserve(service: "A", revision: nil, now: now.addingTimeInterval(600)) }())
    }

    @Test func openCodeFailurePreservesLastSuccessAndSignalsStale() {
        let now = Date()
        var value = UsageSnapshot(source: .opencode, percentUsed: nil, sessionPercent: nil,
                                  resetText: "", updatedAt: .distantPast, syncState: .loading)
        let reading = OpenCodeUsageReader.Reading(percentUsed: 20, rollingPercent: 10,
            limitLabel: "Semanal", limitResetText: "", resetText: "", updatedAt: now)
        value.applyOpenCodeReading(reading)
        value.applyOpenCodeReading(nil)
        #expect(value.percentUsed == 20)
        #expect(value.updatedAt == now)
        #expect(value.syncState == .failed)
        #expect(value.isStale(now: now))
        value.applyOpenCodeReading(reading)
        #expect(value.syncState == .live)
        #expect(value.failureReason == nil)
        #expect(!value.isStale(now: now))
    }

    @Test func shortWindowBlockIsVisibleWithoutChangingMainScale() throws {
        let reading = try #require(OpenCodeUsageReader.parse(Data(#"{"usage":{"rolling":{"percent":100,"status":"rate-limited"},"weekly":{"percent":10},"monthly":{"percent":5}}}"#.utf8)))
        var value = UsageSnapshot(source: .opencode, percentUsed: nil, sessionPercent: nil,
                                  resetText: "", updatedAt: .now, syncState: .loading)
        value.applyOpenCodeReading(reading)
        #expect(value.percentUsed == 10)
        #expect(value.hasBlockedWindow)
        #expect(value.sessionLabel == "Janela curta")
    }

    @Test(arguments: ["-1", "101", "true", "\"12\""])
    func openCodeRejectsInvalidWindow(_ percent: String) {
        let data = Data("{\"usage\":{\"rolling\":{\"percent\":10},\"weekly\":{\"percent\":\(percent)}}}".utf8)
        #expect(OpenCodeUsageReader.parse(data) == nil)
    }

    @Test func providerBlockIsHonoredEvenWithLowPercent() throws {
        let reading = try #require(OpenCodeUsageReader.parse(Data(#"{"usage":{"rolling":{"percent":0,"status":"rate-limited"}}}"#.utf8)))
        #expect(reading.percentUsed == 0)
        #expect(reading.blocked)
    }

    @Test func staleAgeAndUnsafeDisplayAreExplicit() {
        let time = Date()
        var value = UsageSnapshot(source: .codex, percentUsed: 20, sessionPercent: nil,
                                  resetText: "", updatedAt: time, syncState: .live)
        #expect(!value.isStale(now: time.addingTimeInterval(179)))
        #expect(value.isStale(now: time.addingTimeInterval(181)))
        value.percentUsed = 1e300
        #expect(value.displayPercent == "—")
        #expect(UsageValidation.display(.infinity) == "—")
    }

    @Test func incompleteSplitNeverClaimsMeasuredProportion() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"completo":false,"provedores":{"Codex":{"fatia_mac":0,"fatia_vps":100,"mac_tokens":0,"vps_tokens":100}}}"#.utf8).write(to: url)
        let value = try #require(HostSplitReader.read(from: url)["Codex"])
        #expect(!value.isComplete)
        #expect(value.resumo == "Dados incompletos")
        #expect(value.warning != nil)
    }

    @Test func grokHasOneSettingAndExplicitRetryClearsNegativeCache() throws {
        let suite = "usage-island-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            GrokUsageReader.invalidateCookie()
        }
        defaults.set(false, forKey: "grokWebCookies")
        GrokUsageReader.setWebBarEnabled(true, defaults: defaults)
        #expect(defaults.bool(forKey: GrokUsageReader.webBarKey))
        #expect(defaults.object(forKey: "grokWebCookies") == nil)
        #expect(GrokUsageReader.cachedCookieHeader(load: { nil }) == nil)
        #expect(GrokUsageReader.cachedCookieHeader(load: { "fixture" }) == nil)
        GrokUsageReader.setWebBarEnabled(true, defaults: defaults)
        #expect(GrokUsageReader.cachedCookieHeader(load: { "fixture" }) == "fixture")
    }

    @Test func largeCardsFitTheCanvas() {
        let available = IslandMetrics.full(rings: 4).islandHeight
        #expect(IslandLayout.bubbleHeight(rows: 8, splitLine: true) > available)
        #expect(IslandLayout.cardHeight(rows: 8, splitLine: true, availableHeight: available) <= available)
        #expect(IslandLayout.cardHeight(rows: 20, splitLine: true, availableHeight: 300) == 300)
    }

    @Test func missingProviderMarksOnlyItsSplitIncomplete() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"completo":true,"provedores":{"Codex":{"completo":false,"fatia_mac":0,"fatia_vps":100,"mac_tokens":0,"vps_tokens":100}}}"#.utf8).write(to: url)
        #expect(HostSplitReader.read(from: url)["Codex"]?.isComplete == false)
    }
}
