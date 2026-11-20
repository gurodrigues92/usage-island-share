import Foundation
import Testing
@testable import UsageIsland

@MainActor struct MurPowerupTests {
    private func day(_ value: String) -> Date { UsageDay.date(value)! }
    private func term(cents: Int? = 1000, quantity: Int = 1) -> SubscriptionTerm {
        .init(provider: "Codex", name: "Plano", account: "Principal", cents: cents, quantity: quantity, start: day("2024-01-31"))
    }
    private func row(day: String = UsageDay.string(.now)) -> TokenUsageRow {
        .init(id: "row", provider: "Codex", project: "Loja", model: "modelo", day: day, input: 100, output: 20, cacheRead: 30, cacheWrite: 0, cacheWrite1h: 0, calls: 1)
    }
    private func url() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json") }

    @Test func billingCyclesHandleMonthEndLeapDayAndQuantity() throws {
        let value = term(quantity: 2)
        #expect(value.allocatedCents(in: .init(start: day("2024-01-31"), end: day("2024-02-29"))) == 2000)
        #expect(value.allocatedCents(in: .init(start: day("2024-02-29"), end: day("2024-03-31"))) == 2000)
        let partial = try #require(value.allocatedCents(in: .init(start: day("2024-02-01"), end: day("2024-02-02"))))
        #expect(abs(partial - 2000 / 29.0) < 0.0001)
        #expect(value.nextRenewal(now: day("2024-03-01")) == day("2024-03-31"))
        var annual = value; annual.cycle = .yearly
        #expect(annual.allocatedCents(in: .init(start: day("2024-01-31"), end: day("2025-01-31"))) == 2000)
    }
    @Test func unknownPriceIsDifferentFromFreeAndEndingKeepsPayments() throws {
        #expect(term(cents: nil).allocatedCents(in: .init(start: day("2024-01-31"), end: day("2024-02-29"))) == nil)
        #expect(term(cents: 0).allocatedCents(in: .init(start: day("2024-01-31"), end: day("2024-02-29"))) == 0)
        let path = url(); let ledger = SubscriptionLedger(url: path)
        let original = term(quantity: 2); try ledger.add(original)
        let payment = SubscriptionPayment(termID: original.id, date: day("2024-02-01"), cents: 2000)
        try ledger.addPayment(payment); try ledger.end(original.id, on: day("2024-02-15"))
        #expect(ledger.document.payments == [payment])
        #expect(ledger.document.terms[0].renews == false)
        #expect(ledger.totalPaid(currency: "USD", period: .init(start: day("2024-02-01"), end: day("2024-03-01"))) == 2000)
        let loaded = SubscriptionLedger(url: path)
        #expect(loaded.document.terms == ledger.document.terms)
        #expect(loaded.document.payments == [payment])
    }
    @Test func overlappingPriceAndDuplicatePaymentAreRejectedWithoutChangingData() throws {
        let ledger = SubscriptionLedger(url: url()); let original = term(); try ledger.add(original)
        #expect(throws: (any Error).self) { try ledger.add(term(cents: 2000)) }
        #expect(ledger.document.terms.count == 1)
        let p = SubscriptionPayment(termID: original.id, date: day("2024-02-01"), cents: 1000)
        try ledger.addPayment(p)
        #expect(throws: (any Error).self) { try ledger.addPayment(.init(termID: original.id, date: p.date, cents: 1000)) }
        #expect(ledger.document.payments.count == 1)
        try ledger.end(original.id, on: day("2024-02-29"))
        var next = term(cents: 2000); next.start = day("2024-02-29")
        try ledger.add(next); #expect(ledger.document.terms.count == 2)
    }
    @Test func currenciesAreNeverAddedTogetherAndCorruptFileIsNotOverwritten() throws {
        let path = url(); let ledger = SubscriptionLedger(url: path)
        let usd = term(); var brl = term(); brl.currency = "BRL"; brl.account = "Outra conta"
        try ledger.add(usd); try ledger.add(brl)
        try ledger.addPayment(.init(termID: usd.id, date: day("2024-02-01"), cents: 1000))
        try ledger.addPayment(.init(termID: brl.id, date: day("2024-02-01"), cents: 5000))
        let range = DateInterval(start: day("2024-02-01"), end: day("2024-03-01"))
        #expect(ledger.totalPaid(currency: "USD", period: range) == 1000)
        #expect(ledger.totalPaid(currency: "BRL", period: range) == 5000)
        try Data("invalid".utf8).write(to: path)
        let corrupt = SubscriptionLedger(url: path)
        #expect(corrupt.issue != nil)
        #expect(throws: (any Error).self) { try corrupt.add(term()) }
        #expect(try String(contentsOf: path, encoding: .utf8) == "invalid")
    }
    @Test func correctingPriceKeepsPaymentsAndCannotRewriteTheirCurrency() throws {
        let ledger = SubscriptionLedger(url: url()); var value = term(); try ledger.add(value)
        let payment = SubscriptionPayment(termID: value.id, date: day("2024-02-01"), cents: 1000)
        try ledger.addPayment(payment)
        value.cents = 2000; try ledger.update(value)
        #expect(ledger.document.terms[0].cents == 2000)
        #expect(ledger.document.payments == [payment])
        value.currency = "BRL"
        #expect(throws: (any Error).self) { try ledger.update(value) }
        #expect(ledger.document.terms[0].currency == "USD")
        #expect(throws: (any Error).self) { try ledger.end(value.id, on: value.start.addingTimeInterval(3600)) }
        #expect(ledger.document.terms[0].end == nil)
    }
    @Test func portableImportsReplaceNewerDaysWithoutDoubleCounting() throws {
        let local = UUID().uuidString; var value = ImportedUsage()
        let now = Date.now.addingTimeInterval(-10)
        var package = PortableUsage(machineID: UUID().uuidString, machineName: "Outro Mac", capturedAt: now, firstDay: UsageDay.string(now), lastDay: UsageDay.string(now), rows: [row(day: UsageDay.string(now))])
        try value.merge(package, localID: local); try value.merge(package, localID: local)
        #expect(value.entries.count == 1)
        package.rows[0].input = 200; package.capturedAt = now.addingTimeInterval(5)
        try value.merge(package, localID: local)
        #expect(value.rows[0].input == 200)
        package.rows[0].input = 50; package.capturedAt = now.addingTimeInterval(-5)
        try value.merge(package, localID: local)
        #expect(value.rows[0].input == 200)
        package.capturedAt = now.addingTimeInterval(6); package.rows = []
        try value.merge(package, localID: local); #expect(value.entries.isEmpty)
        package.machineID = local
        #expect(throws: (any Error).self) { try value.merge(package, localID: local) }
    }
    @Test func portableImportPersistsAndRejectsMalformedDatesAndFutureSnapshots() throws {
        let suite = "UsageIsland-Import-" + UUID().uuidString; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let path = url(); let analytics = UsageAnalytics(importURL: path, defaults: defaults)
        let now = Date.now
        var package = PortableUsage(machineID: UUID().uuidString, machineName: "Mac 2", capturedAt: now, firstDay: UsageDay.string(now), lastDay: UsageDay.string(now), rows: [row()])
        try analytics.importData(JSONEncoder().encode(package))
        let loaded = UsageAnalytics(importURL: path, defaults: defaults)
        #expect(loaded.rows.count == 1)
        package.rows[0].day = "2026-99-99"
        #expect(!package.valid)
        #expect(throws: (any Error).self) { try analytics.importData(JSONEncoder().encode(package)) }
        #expect(analytics.rows.count == 1)
        package.rows = []; package.capturedAt = now.addingTimeInterval(600)
        #expect(!package.valid)
    }
    @Test func costBoundsCsvAndSharedFiltersPreserveUnknowns() {
        var record = row(day: "2026-10-22")
        #expect(TechnicalCost(rows: [record], prices: []).label == "Não apurado")
        let price = ModelPrice(model: "modelo", input: 1, output: 2, cacheRead: 0.1, cacheWrite: 1)
        var unknown = record; unknown.id = "other"; unknown.model = "desconhecido"
        #expect(TechnicalCost(rows: [record, unknown], prices: [price]).unknownRows == 1)
        #expect(TechnicalCost(rows: [record, unknown], prices: [price]).label.hasPrefix("Pelo menos"))
        record.project = "=formula,\"loja\""
        let csv = String(data: UsageCSV.rows([record, unknown], prices: [price]), encoding: .utf8)!
        #expect(csv.contains("'=formula,"))
        #expect(csv.contains("Não apurado"))
        var filter = AnalysisFilter(days: 1)
        #expect(filter.includes(record, now: day("2026-10-22")))
        filter.provider = "Claude"; #expect(!filter.includes(record, now: day("2026-10-22")))
        filter.provider = "Codex"; filter.search = "loja"; #expect(filter.includes(record, now: day("2026-10-22")))
        filter.machine = "VPS"; #expect(!filter.includes(record, now: day("2026-10-22")))
    }
    @Test func themeMigrationPreservesExistingMotionAndIcons() throws {
        var prefs = UsagePreferences(); prefs.animationSpeed = 2
        let old = try JSONEncoder().encode(prefs)
        #expect(try JSONDecoder().decode(UsagePreferences.self, from: old).theme == .dark)
        prefs.theme = .light
        let decoded = try JSONDecoder().decode(UsagePreferences.self, from: JSONEncoder().encode(prefs))
        #expect(decoded.theme == .light); #expect(decoded.animationSpeed == 2)
    }
    @Test func datePickerPreservesCivilDateAcrossNegativeAndPositiveOffsets() {
        let civilDay = day("2026-10-22")
        for zone in ["America/Sao_Paulo", "Pacific/Kiritimati", "UTC"] {
            var local = Calendar(identifier: .gregorian); local.timeZone = TimeZone(identifier: zone)!
            let picker = UsageDay.pickerDate(civilDay, calendar: local)
            #expect(local.component(.day, from: picker) == 22)
            #expect(UsageDay.fromPicker(picker, calendar: local) == civilDay)
        }
        #expect(UsageDay.date("2023-02-29") == nil)
        #expect(UsageDay.date("2024-02-29") != nil)
    }
    @Test func portableExportRequiresCompleteRecentCollectionAndKeepsCaptureTime() throws {
        let suite = "UsageIsland-Export-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let analytics = UsageAnalytics(importURL: url(), defaults: defaults)
        #expect(!analytics.canExportPortableUsage)
        #expect(throws: (any Error).self) { try analytics.portableData() }
        let now = Date.now, captured = now.addingTimeInterval(-120)
        var local = row(day: UsageDay.string(captured))
        local.input = 500
        var document = AnalyticsDocument(rows: [local], incomplete: false, updatedAt: captured.ISO8601Format(), warnings: [])
        let package = try PortableUsage.localSnapshot(document, machineID: analytics.machineID, name: "Mac", now: now)
        #expect(package.capturedAt == UsageDates.parse(document.updatedAt))
        #expect(package.capturedAt < now)
        #expect(package.rows == [local])
        var receiver = ImportedUsage()
        var newer = package; newer.capturedAt = now.addingTimeInterval(-60); newer.rows[0].input = 900
        let otherMac = UUID().uuidString
        try receiver.merge(newer, localID: otherMac)
        // Re-exporting an older successful collection cannot erase newer counters.
        try receiver.merge(package, localID: otherMac)
        #expect(receiver.rows[0].input == 900)
        document.incomplete = true
        #expect(throws: (any Error).self) { try PortableUsage.localSnapshot(document, machineID: analytics.machineID, name: "Mac", now: now) }
        document.incomplete = false; document.warnings = ["Registros ignorados"]
        #expect(throws: (any Error).self) { try PortableUsage.localSnapshot(document, machineID: analytics.machineID, name: "Mac", now: now) }
        document.warnings = []; document.updatedAt = now.addingTimeInterval(-601).ISO8601Format()
        #expect(throws: (any Error).self) { try PortableUsage.localSnapshot(document, machineID: analytics.machineID, name: "Mac", now: now) }
        document.updatedAt = now.addingTimeInterval(301).ISO8601Format()
        #expect(throws: (any Error).self) { try PortableUsage.localSnapshot(document, machineID: analytics.machineID, name: "Mac", now: now) }
        // Complete empty collections remain meaningful; only uncollected/partial ones are blocked.
        document.updatedAt = captured.ISO8601Format(); document.rows = []
        #expect(try PortableUsage.localSnapshot(document, machineID: analytics.machineID, name: "Mac", now: now).rows.isEmpty)
    }
    @Test func portableImportRejectsUnknownSchemaAndMoreThanSevenInclusiveDays() throws {
        let now = Date.now, today = UsageDay.string(.now)
        var package = PortableUsage(machineID: UUID().uuidString, machineName: "Mac 2", capturedAt: now,
                                    firstDay: today, lastDay: today, rows: [row()])
        package.version = 999
        var receiver = ImportedUsage()
        #expect(!package.valid)
        #expect(throws: (any Error).self) { try receiver.merge(package, localID: UUID().uuidString) }
        #expect(receiver.entries.isEmpty)
        package.version = 1
        package.firstDay = UsageDay.string(UsageDay.calendar.date(byAdding: .day, value: -6, to: now)!)
        #expect(package.valid)
        package.firstDay = UsageDay.string(UsageDay.calendar.date(byAdding: .day, value: -7, to: now)!)
        #expect(!package.valid)
    }
    @Test func exactModelTariffOverridesBaseAliasRegardlessOfListOrder() {
        var record = row(); record.model = "claude-sonnet-4-5-20250929"; record.input = 1_000_000
        record.output = 0; record.cacheRead = 0
        let base = ModelPrice(model: "claude-sonnet-4-5", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)
        let exact = ModelPrice(model: record.model, input: 7, output: 35, cacheRead: 0.7, cacheWrite: 8.75)
        #expect(record.apiEquivalent(prices: [base, exact]) == 7)
        #expect(record.apiEquivalent(prices: [exact, base]) == 7)
        #expect(record.apiEquivalent(prices: [base]) == 3)
    }
    @Test func receiptCannotUseExpiredOrFuturePlansToCoverCurrentProviders() {
        let range = DateInterval(start: day("2026-10-01"), end: day("2026-11-01"))
        var active = term(); active.start = range.start
        var claude = term(); claude.provider = "Claude"; claude.start = day("2026-08-01"); claude.end = day("2026-09-01")
        var claudeRow = row(day: "2026-10-25"); claudeRow.provider = "Claude"
        let records = [row(day: "2026-10-25"), claudeRow]
        #expect(!SubscriptionTerm.permitsUSDComparison(terms: [active, claude], rows: records, period: range))
        claude.start = day("2026-11-01"); claude.end = nil
        #expect(!SubscriptionTerm.permitsUSDComparison(terms: [active, claude], rows: records, period: range))
        claude.start = range.start
        #expect(SubscriptionTerm.permitsUSDComparison(terms: [active, claude], rows: records, period: range))
        claude.end = day("2026-10-25")
        #expect(!SubscriptionTerm.permitsUSDComparison(terms: [active, claude], rows: records, period: range))
        claude.end = day("2026-10-26")
        #expect(SubscriptionTerm.permitsUSDComparison(terms: [active, claude], rows: records, period: range))
        claude.start = day("2026-10-26"); claude.end = nil
        #expect(!SubscriptionTerm.permitsUSDComparison(terms: [active, claude], rows: records, period: range))
        claude.start = day("2026-10-25")
        #expect(SubscriptionTerm.permitsUSDComparison(terms: [active, claude], rows: records, period: range))
        claude.cents = nil
        #expect(!SubscriptionTerm.permitsUSDComparison(terms: [active, claude], rows: records, period: range))
        claude.cents = 1000; claude.currency = "BRL"
        #expect(!SubscriptionTerm.permitsUSDComparison(terms: [active, claude], rows: records, period: range))
    }

}
