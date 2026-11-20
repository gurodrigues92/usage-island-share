import Foundation
import Testing
@testable import UsageIsland

@MainActor struct ReceiptCoverageTests {
    private func day(_ value: String) -> Date { UsageDay.date(value)! }
    private var period: DateInterval { .init(start: day("2024-04-01"), end: day("2024-05-01")) }
    private func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("ledger.json") }
    private func plan(currency: String = "USD", cents: Int? = 2400, quantity: Int = 1, cycle: BillingCycle = .monthly) -> SubscriptionTerm {
        .init(provider: "Provider A", name: "Fixture plan", account: "Fixture account", currency: currency, cents: cents, quantity: quantity, cycle: cycle, start: day("2024-04-01"))
    }
    @Test func confirmedSubscriptionAndPaymentDoNotDependOnAPITariffs() throws {
        let ledger = SubscriptionLedger(url: file()), term = plan()
        try ledger.add(term)
        try ledger.addPayment(.init(termID: term.id, date: day("2024-04-02"), cents: 2400))
        let usage = TokenUsageRow(id: "fixture", provider: term.provider, project: "Fixture", model: "unknown-model", day: "2024-04-02", input: 100, output: 0, cacheRead: 0, cacheWrite: 0, cacheWrite1h: 0, calls: 1)
        #expect(TechnicalCost(rows: [usage], prices: []).label == "Não apurado")
        let receipt = try #require(ledger.receipt(period: period, now: day("2024-04-15")).first)
        #expect(receipt.monthlyCents == 2400)
        #expect(receipt.proportionalCents == 2400)
        #expect(receipt.paidCents == 2400)
        #expect(receipt.paymentCount == 1)
        #expect(receipt.proportionalKnownPlans == 1)
    }
    @Test func annualEquivalentAndProrationRemainDistinctFromActualPayment() throws {
        let ledger = SubscriptionLedger(url: file()), annual = plan(cents: 12000, quantity: 3, cycle: .yearly)
        try ledger.add(annual)
        try ledger.addPayment(.init(termID: annual.id, date: day("2024-04-01"), cents: 36000))
        let receipt = try #require(ledger.receipt(period: period, now: day("2024-04-15")).first)
        #expect(receipt.monthlyCents == 3000)
        #expect(abs(receipt.proportionalCents - 36000 * 30.0 / 365.0) < 0.0001)
        #expect(receipt.paidCents == 36000) // the payment is already the total for all three accounts
    }
    @Test func chargedCurrencyDoesNotDoubleCountContractCurrency() throws {
        let path = file(), ledger = SubscriptionLedger(url: path), term = plan()
        try ledger.add(term)
        try ledger.addPayment(.init(termID: term.id, date: day("2024-04-02"), cents: 12345, currency: "BRL"))
        let receipts = ledger.receipt(period: period, now: day("2024-04-15"))
        let usd = try #require(receipts.first { $0.currency == "USD" })
        let brl = try #require(receipts.first { $0.currency == "BRL" })
        #expect(usd.monthlyCents == 2400)
        #expect(usd.paidCents == 0 && usd.paymentCount == 0)
        #expect(brl.monthlyLabel == "Sem plano ativo")
        #expect(brl.paidCents == 12345 && brl.paymentCount == 1)
        #expect(ledger.totalPaid(currency: "USD", period: period) == 0)
        #expect(ledger.totalPaid(currency: "BRL", period: period) == 12345)
        let reloaded = SubscriptionLedger(url: path)
        #expect(reloaded.document.payments.first?.currency == "BRL")
        #expect(reloaded.totalPaid(currency: "BRL", period: period) == 12345)
    }
    @Test func unknownPlanCostIsNotZeroAndDoesNotHideConfirmedPayment() throws {
        let ledger = SubscriptionLedger(url: file()), term = plan(cents: nil)
        try ledger.add(term)
        try ledger.addPayment(.init(termID: term.id, date: day("2024-04-02"), cents: 1700))
        let unknown = try #require(ledger.receipt(period: period, now: day("2024-04-15")).first)
        #expect(unknown.monthlyLabel == "A confirmar")
        #expect(unknown.proportionalLabel == "A confirmar")
        #expect(unknown.paidCents == 1700)
        var free = plan(cents: 0); free.account = "Free fixture"
        try ledger.add(free)
        let partial = try #require(ledger.receipt(period: period, now: day("2024-04-15")).first)
        #expect(partial.monthlyKnownPlans == 1 && partial.monthlyUnknownPlans == 1)
        #expect(partial.monthlyLabel.hasPrefix("Pelo menos "))
        #expect(partial.proportionalLabel.hasPrefix("Pelo menos "))
    }
    @Test func receiptEvidenceImportIsIdempotentAndConflictsArePreserved() throws {
        let path = file(), ledger = SubscriptionLedger(url: path), term = plan()
        try ledger.add(term)
        let evidence = SubscriptionEvidence(source: "Fixture source", reference: "opaque-fixture-reference")
        let payment = SubscriptionPayment(termID: term.id, date: day("2024-04-02"), cents: 12345, currency: "BRL", evidence: evidence)
        try ledger.importConfirmedPayment(payment)
        var repeated = payment; repeated.id = UUID()
        try ledger.importConfirmedPayment(repeated)
        #expect(ledger.document.payments.count == 1)
        let original = try Data(contentsOf: path)
        repeated.cents = 12346
        #expect(throws: (any Error).self) { try ledger.importConfirmedPayment(repeated) }
        #expect(try Data(contentsOf: path) == original)
        repeated.cents = payment.cents; repeated.currency = "EUR"
        #expect(throws: (any Error).self) { try ledger.importConfirmedPayment(repeated) }
        #expect(try Data(contentsOf: path) == original)
        let reloaded = SubscriptionLedger(url: path)
        #expect(reloaded.document.payments == [payment])
        #expect(try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int == 0o600)
    }
    @Test func evidenceCanAttachToExistingManualPaymentWithoutDuplication() throws {
        let ledger = SubscriptionLedger(url: file()), term = plan()
        try ledger.add(term)
        let manual = SubscriptionPayment(termID: term.id, date: day("2024-04-02"), cents: 2400)
        try ledger.addPayment(manual)
        let evidence = SubscriptionEvidence(source: "Fixture", reference: "manual-match")
        try ledger.importConfirmedPayment(.init(termID: term.id, date: manual.date, cents: manual.cents, currency: "USD", evidence: evidence))
        #expect(ledger.document.payments.count == 1)
        #expect(ledger.document.payments[0].id == manual.id)
        #expect(ledger.document.payments[0].evidence == evidence)
        #expect(ledger.totalPaid(currency: "USD", period: period) == 2400)
    }
    @Test func legacyPaymentInheritsCurrencyAndProviderPeriodFiltersApply() throws {
        let path = file(), term = plan(currency: "EUR")
        let oldPayment = SubscriptionPayment(termID: term.id, date: day("2024-04-01"), cents: 2400)
        let old = SubscriptionLedger.Document(terms: [term], payments: [oldPayment])
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(old).write(to: path)
        let ledger = SubscriptionLedger(url: path)
        #expect(ledger.issue == nil)
        #expect(ledger.document.payments[0].currency == nil)
        #expect(ledger.paymentCurrency(ledger.document.payments[0]) == "EUR")
        try ledger.addPayment(.init(termID: term.id, date: period.end, cents: 2400))
        #expect(ledger.totalPaid(currency: "EUR", period: period) == 2400)
        #expect(ledger.totalPaid(currency: "EUR", period: period, provider: "Different provider") == 0)
        #expect(ledger.receipt(period: period, provider: "Different provider", now: day("2024-04-15")).isEmpty)
        #expect(!SubscriptionPayment(termID: term.id, date: period.start, cents: 1, currency: "INVALID").valid)
    }
    @Test func financialCSVSeparatesContractCostsFromOneActualPaymentCurrency() throws {
        let ledger = SubscriptionLedger(url: file()), term = plan()
        try ledger.add(term)
        try ledger.importConfirmedPayment(.init(termID: term.id, date: day("2024-04-02"), cents: 12345, currency: "BRL",
            evidence: .init(source: "Fixture source", reference: "private-reference-not-for-export")))
        let csv = String(decoding: ledger.financialCSV(period: period, now: day("2024-04-15")), as: UTF8.self)
        let rows = csv.components(separatedBy: "\r\n").map { $0.components(separatedBy: "\",\"").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) } }
        #expect(rows.allSatisfy { $0.count == 14 })
        let payments = rows.filter { $0[0] == "Pagamento" }
        #expect(payments.count == 1)
        #expect(payments[0][4] == "BRL")
        #expect(payments[0][5] == "Total cobrado")
        #expect(payments[0][6] == "123.450000")
        #expect(payments[0][13] == "Fixture source")
        #expect(!csv.contains("private-reference-not-for-export"))
        let usdPaymentSummary = try #require(rows.first { $0[0] == "Resumo" && $0[4] == "USD" && $0[5] == "Pagamentos registrados no período" })
        #expect(usdPaymentSummary[6].isEmpty)
        #expect(usdPaymentSummary[7] == "Sem pagamentos registrados")
        let monthly = try #require(rows.first { $0[0] == "Resumo" && $0[4] == "USD" && $0[5] == "Equivalente mensal atual" })
        #expect(monthly[6] == "24.000000")
        #expect(monthly[10] == "2024-04-15" && monthly[11].isEmpty && monthly[12].isEmpty)
        let prorata = try #require(rows.first { $0[0] == "Resumo" && $0[4] == "USD" && $0[5] == "Custo proporcional do período" })
        #expect(prorata[11] == "2024-04-01" && prorata[12] == "2024-05-01")
    }
    @Test func financialCSVPreservesUnknownsAndFiltersProviderAndPaymentPeriod() throws {
        let ledger = SubscriptionLedger(url: file()), unknown = plan(currency: "EUR", cents: nil)
        try ledger.add(unknown)
        var another = plan(); another.provider = "Excluded provider"
        try ledger.add(another)
        try ledger.addPayment(.init(termID: another.id, date: day("2024-04-02"), cents: 8888))
        try ledger.addPayment(.init(termID: unknown.id, date: day("2024-03-31"), cents: 7777))
        try ledger.addPayment(.init(termID: unknown.id, date: period.end, cents: 6666))
        let csv = String(decoding: ledger.financialCSV(period: period, provider: unknown.provider, now: day("2024-04-15")), as: UTF8.self)
        let rows = csv.components(separatedBy: "\r\n").map { $0.components(separatedBy: "\",\"").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) } }
        #expect(!csv.contains("Excluded provider"))
        #expect(rows.filter { $0[0] == "Pagamento" }.isEmpty)
        let term = try #require(rows.first { $0[0] == "Plano" })
        #expect(term[4] == "EUR" && term[6].isEmpty && term[7] == "A confirmar")
        let monthly = try #require(rows.first { $0[0] == "Resumo" && $0[5] == "Equivalente mensal atual" })
        let prorata = try #require(rows.first { $0[0] == "Resumo" && $0[5] == "Custo proporcional do período" })
        #expect(monthly[6].isEmpty && monthly[7] == "A confirmar")
        #expect(prorata[6].isEmpty && prorata[7] == "A confirmar")
    }

}
