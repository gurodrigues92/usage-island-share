import Combine
import Foundation

enum UsageDay {
    static let calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }()
    static func string(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    static func date(_ value: String) -> Date? {
        let b = Array(value.utf8)
        guard b.count == 10, b[4] == 45, b[7] == 45, [0,1,2,3,5,6,8,9].allSatisfy({ (48...57).contains(b[$0]) }) else { return nil }
        let y = Int(b[0]-48)*1000 + Int(b[1]-48)*100 + Int(b[2]-48)*10 + Int(b[3]-48)
        let m = Int(b[5]-48)*10 + Int(b[6]-48), d = Int(b[8]-48)*10 + Int(b[9]-48)
        guard (1900...2200).contains(y), (1...12).contains(m), (1...31).contains(d),
              let result = calendar.date(from: DateComponents(year: y, month: m, day: d)), string(result) == value else { return nil }
        return result
    }
    /// AppKit date-only pickers use the local calendar. Preserve the civil day,
    /// rather than reinterpreting UTC midnight as the preceding local date.
    static func pickerDate(_ civilDay: Date, calendar local: Calendar = .current) -> Date {
        let parts = calendar.dateComponents([.year, .month, .day], from: civilDay)
        return local.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day)) ?? civilDay
    }
    static func fromPicker(_ value: Date, calendar local: Calendar = .current) -> Date {
        let parts = local.dateComponents([.year, .month, .day], from: value)
        return calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day)) ?? value
    }
}

struct AnalysisFilter: Equatable {
    var days = 30
    var provider = "Todos"
    var machine = "Todas"
    var model = "Todos"
    var search = ""
    func interval(now: Date = .now) -> DateInterval {
        let end = UsageDay.calendar.date(byAdding: .day, value: 1, to: UsageDay.calendar.startOfDay(for: now))!
        return DateInterval(start: UsageDay.calendar.date(byAdding: .day, value: -min(365, max(1, days)), to: end)!, end: end)
    }
    func includes(_ row: TokenUsageRow, now: Date = .now) -> Bool {
        let range = interval(now: now)
        return row.day >= UsageDay.string(range.start) && row.day < UsageDay.string(range.end)
            && (provider == "Todos" || provider == row.provider)
            && (machine == "Todas" || machine == (row.machine ?? "Mac"))
            && (model == "Todos" || model == row.model)
            && (search.isEmpty || (row.project + " " + row.model).localizedCaseInsensitiveContains(search))
    }
    func apply(to rows: [TokenUsageRow], now: Date = .now) -> [TokenUsageRow] {
        let range = interval(now: now); let first = UsageDay.string(range.start), end = UsageDay.string(range.end)
        return rows.filter { row in row.day >= first && row.day < end
            && (provider == "Todos" || provider == row.provider) && (machine == "Todas" || machine == (row.machine ?? "Mac"))
            && (model == "Todos" || model == row.model) && (search.isEmpty || (row.project + " " + row.model).localizedCaseInsensitiveContains(search)) }
    }
}

struct TechnicalCost {
    var dollars: Double
    var unknownRows: Int
    var rowCount: Int
    init(rows: [TokenUsageRow], prices: [ModelPrice]) {
        let known = rows.compactMap { $0.apiEquivalent(prices: prices) }
        dollars = known.reduce(0, +); unknownRows = rows.count - known.count; rowCount = rows.count
    }
    var label: String {
        if rowCount == 0 { return "Sem registros" }
        if unknownRows == rowCount { return "Não apurado" }
        return (unknownRows > 0 ? "Pelo menos " : "") + dollars.formatted(.currency(code: "USD"))
    }
}

enum BillingCycle: String, Codable, CaseIterable { case monthly, yearly
    var title: String { self == .monthly ? "Mensal" : "Anual" }
    var months: Int { self == .monthly ? 1 : 12 }
}

struct SubscriptionTerm: Codable, Equatable, Identifiable {
    var id = UUID()
    var provider: String
    var name: String
    var account: String
    var currency = "USD"
    var cents: Int?
    var quantity = 1
    var cycle = BillingCycle.monthly
    var start: Date
    /// First day without this price/access. Ending a price period preserves its payments.
    var end: Date? = nil
    var renews = true
    var valid: Bool {
        !provider.isEmpty && provider.count <= 80 && !name.trimmingCharacters(in: .whitespaces).isEmpty && name.count <= 100
            && !account.trimmingCharacters(in: .whitespaces).isEmpty && account.count <= 80
            && ["USD", "BRL", "EUR"].contains(currency) && (1...100).contains(quantity)
            && (cents == nil || (0...1_000_000_000).contains(cents!))
            && start.timeIntervalSince1970.isFinite && (end == nil || (end! > start && end!.timeIntervalSince1970.isFinite))
    }
    func overlaps(_ period: DateInterval) -> Bool { start < period.end && (end ?? .distantFuture) > period.start }
    static func permitsUSDComparison(terms: [SubscriptionTerm], rows: [TokenUsageRow], period: DateInterval) -> Bool {
        let active = terms.filter { $0.overlaps(period) }
        guard !rows.isEmpty, active.allSatisfy({ $0.valid && $0.currency == "USD" && $0.cents != nil }) else { return false }
        return rows.allSatisfy { row in
            guard let day = UsageDay.date(row.day), day >= period.start, day < period.end else { return false }
            return active.contains { $0.provider == row.provider && $0.start <= day && ($0.end ?? .distantFuture) > day }
        }
    }
    func allocatedCents(in period: DateInterval) -> Double? {
        guard valid, let cents else { return nil }
        let a = max(UsageDay.calendar.startOfDay(for: start), period.start)
        let b = min(end.map { UsageDay.calendar.startOfDay(for: $0) } ?? period.end, period.end)
        guard b > a else { return 0 }
        let months = UsageDay.calendar.dateComponents([.month], from: start, to: a).month ?? 0
        var index = max(0, months / cycle.months - 1); var total = 0.0
        // Bound malformed/imported dates, without iterating every day since the plan began.
        for _ in 0..<500 {
            guard let from = UsageDay.calendar.date(byAdding: .month, value: index * cycle.months, to: start),
                  let to = UsageDay.calendar.date(byAdding: .month, value: (index + 1) * cycle.months, to: start), to > from else { break }
            if from >= b { break }
            let overlap = max(0, min(b, to).timeIntervalSince(max(a, from)))
            total += Double(cents) * Double(quantity) * overlap / to.timeIntervalSince(from)
            index += 1
        }
        return total
    }
    func nextRenewal(now: Date = .now) -> Date? {
        guard valid, renews, end == nil || end! > now else { return nil }
        let months = max(0, UsageDay.calendar.dateComponents([.month], from: start, to: now).month ?? 0)
        for n in max(0, months / cycle.months - 1)...(months / cycle.months + 2) {
            if let date = UsageDay.calendar.date(byAdding: .month, value: n * cycle.months, to: start), date > now,
               end == nil || date < end! { return date }
        }
        return nil
    }
}

/// A private locator for a verified receipt, never its contents or credentials.
struct SubscriptionEvidence: Codable, Equatable {
    var source: String
    var reference: String
    var valid: Bool { !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && source.count <= 80
        && !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && reference.count <= 512 }
}

struct SubscriptionPayment: Codable, Equatable, Identifiable {
    var id = UUID()
    var termID: UUID
    var date: Date
    /// Total actually paid, including all accounts. Never multiply this by quantity.
    var cents: Int
    /// Nil preserves the original format: inherit the subscription's currency.
    var currency: String? = nil
    var evidence: SubscriptionEvidence? = nil
    var valid: Bool { (0...1_000_000_000).contains(cents) && date.timeIntervalSince1970.isFinite
        && (currency == nil || ["USD", "BRL", "EUR"].contains(currency!)) && (evidence?.valid ?? true) }
}

struct SubscriptionReceipt: Identifiable {
    var currency: String
    var monthlyCents: Double
    var monthlyKnownPlans: Int
    var monthlyUnknownPlans: Int
    var proportionalCents: Double
    var proportionalKnownPlans: Int
    var proportionalUnknownPlans: Int
    var paidCents: Int
    var paymentCount: Int
    var id: String { currency }
    var monthlyLabel: String { amountLabel(monthlyCents, known: monthlyKnownPlans, unknown: monthlyUnknownPlans, empty: "Sem plano ativo") }
    var proportionalLabel: String { amountLabel(proportionalCents, known: proportionalKnownPlans, unknown: proportionalUnknownPlans, empty: "Sem plano no período") }
    var paymentLabel: String { paymentCount == 0 ? "Sem pagamentos registrados" : (Double(paidCents) / 100).formatted(.currency(code: currency)) }
    private func amountLabel(_ cents: Double, known: Int, unknown: Int, empty: String) -> String {
        if known == 0 { return unknown > 0 ? "A confirmar" : empty }
        return (unknown > 0 ? "Pelo menos " : "") + (cents / 100).formatted(.currency(code: currency))
    }
}

@MainActor final class SubscriptionLedger: ObservableObject {
    struct Document: Codable { var version = 1; var terms: [SubscriptionTerm] = []; var payments: [SubscriptionPayment] = [] }
    @Published private(set) var document = Document()
    @Published private(set) var issue: String?
    private let url: URL
    private var writable = true
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Usage Island/subscriptions.json")
        guard FileManager.default.fileExists(atPath: self.url.path) else { return }
        do {
            let data = try Data(contentsOf: self.url)
            guard data.count <= 2 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            let value = try JSONDecoder().decode(Document.self, from: data)
            guard value.version == 1, value.terms.allSatisfy(\.valid), Set(value.terms.map(\.id)).count == value.terms.count,
                  Set(value.payments.map(\.id)).count == value.payments.count,
                  value.payments.allSatisfy({ p in p.valid && value.terms.contains { $0.id == p.termID } }) else { throw CocoaError(.fileReadCorruptFile) }
            document = value
        } catch { writable = false; issue = "Não foi possível ler as assinaturas. O arquivo original foi preservado; nenhum dado será sobrescrito." }
    }
    func add(_ term: SubscriptionTerm) throws {
        guard term.valid, !document.terms.contains(where: { $0.id == term.id }) else { throw LedgerError.invalid }
        guard !document.terms.contains(where: {
            $0.provider == term.provider && $0.account.caseInsensitiveCompare(term.account) == .orderedSame
                && $0.start < (term.end ?? .distantFuture) && term.start < ($0.end ?? .distantFuture)
        }) else { throw LedgerError.overlap }
        var next = document; next.terms.append(term); try save(next)
    }
    func setRenewal(_ id: UUID, enabled: Bool) throws {
        var next = document; guard let index = next.terms.firstIndex(where: { $0.id == id }) else { throw LedgerError.invalid }
        next.terms[index].renews = enabled; try save(next)
    }
    func update(_ term: SubscriptionTerm) throws {
        var next = document
        guard term.valid, let index = next.terms.firstIndex(where: { $0.id == term.id }) else { throw LedgerError.invalid }
        if next.terms[index].currency != term.currency, next.payments.contains(where: { $0.termID == term.id }) { throw LedgerError.currencyHasPayments }
        guard !next.terms.contains(where: { $0.id != term.id && $0.provider == term.provider && $0.account.caseInsensitiveCompare(term.account) == .orderedSame && $0.start < (term.end ?? .distantFuture) && term.start < ($0.end ?? .distantFuture) }) else { throw LedgerError.overlap }
        next.terms[index] = term; try save(next)
    }
    func end(_ id: UUID, on date: Date) throws {
        let end = UsageDay.calendar.startOfDay(for: date)
        var next = document; guard let index = next.terms.firstIndex(where: { $0.id == id }), end > next.terms[index].start else { throw LedgerError.invalid }
        next.terms[index].end = end; next.terms[index].renews = false; try save(next)
    }
    func addPayment(_ payment: SubscriptionPayment) throws {
        guard payment.valid,
              document.terms.contains(where: { $0.id == payment.termID }), !document.payments.contains(where: { $0.id == payment.id }) else { throw LedgerError.invalid }
        guard !document.payments.contains(where: { $0.termID == payment.termID && UsageDay.string($0.date) == UsageDay.string(payment.date) && $0.cents == payment.cents && paymentCurrency($0) == paymentCurrency(payment) }) else { throw LedgerError.duplicatePayment }
        if let evidence = payment.evidence, document.payments.contains(where: { $0.evidence == evidence }) { throw LedgerError.evidenceConflict }
        var next = document; next.payments.append(payment); try save(next)
    }
    /// Repeat imports of the same verified receipt are harmless. Conflicting facts are never overwritten.
    func importConfirmedPayment(_ payment: SubscriptionPayment) throws {
        guard payment.valid, let evidence = payment.evidence, document.terms.contains(where: { $0.id == payment.termID }) else { throw LedgerError.invalid }
        let sameFacts: (SubscriptionPayment) -> Bool = {
            $0.termID == payment.termID && UsageDay.string($0.date) == UsageDay.string(payment.date) && $0.cents == payment.cents && self.paymentCurrency($0) == self.paymentCurrency(payment)
        }
        if let previous = document.payments.first(where: { $0.evidence == evidence }) {
            guard sameFacts(previous) else { throw LedgerError.evidenceConflict }
            return
        }
        if let index = document.payments.firstIndex(where: sameFacts), document.payments[index].evidence == nil {
            var next = document; next.payments[index].evidence = evidence; try save(next); return
        }
        try addPayment(payment)
    }
    func receipt(period: DateInterval, provider: String = "Todos", now: Date = .now) -> [SubscriptionReceipt] {
        let terms = document.terms.filter { provider == "Todos" || $0.provider == provider }
        let payments = document.payments.filter { $0.date >= period.start && $0.date < period.end }
        return ["USD", "BRL", "EUR"].compactMap { currency in
            let matching = terms.filter { $0.currency == currency }
            let inPeriod = matching.filter { $0.overlaps(period) }
            let current = matching.filter { $0.start <= now && ($0.end ?? .distantFuture) > now }
            let ids = Set(terms.map(\.id))
            let paid = payments.filter { ids.contains($0.termID) && paymentCurrency($0) == currency }
            guard !inPeriod.isEmpty || !current.isEmpty || !paid.isEmpty else { return nil }
            return SubscriptionReceipt(currency: currency,
                monthlyCents: current.compactMap { term in term.cents.map { Double($0) * Double(term.quantity) / Double(term.cycle.months) } }.reduce(0, +),
                monthlyKnownPlans: current.filter { $0.cents != nil }.count, monthlyUnknownPlans: current.filter { $0.cents == nil }.count,
                proportionalCents: inPeriod.compactMap { $0.allocatedCents(in: period) }.reduce(0, +),
                proportionalKnownPlans: inPeriod.filter { $0.cents != nil }.count, proportionalUnknownPlans: inPeriod.filter { $0.cents == nil }.count,
                paidCents: paid.reduce(0) { $0 + $1.cents }, paymentCount: paid.count)
        }
    }
    /// Financial values have separate typed rows; consumers must not sum across measures.
    func financialCSV(period: DateInterval, provider: String = "Todos", now: Date = .now) -> Data {
        let terms = document.terms.filter { provider == "Todos" || $0.provider == provider }
        let ids = Set(terms.map(\.id))
        let payments = document.payments.filter { ids.contains($0.termID) && $0.date >= period.start && $0.date < period.end }
        let paidIDs = Set(payments.map(\.termID))
        var lines = [["Tipo", "Provedor", "Plano", "Conta", "Moeda", "Medida", "Valor", "Estado", "Quantidade", "Ciclo", "Data", "Início", "Fim exclusivo", "Fonte do comprovante"]]
        func money(_ cents: Double?) -> String { cents.map { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), $0 / 100) } ?? "" }
        func state(known: Int, unknown: Int, empty: String) -> String {
            if known == 0 { return unknown > 0 ? "A confirmar" : empty }
            return unknown > 0 ? "Parcial" : "Calculado"
        }
        for value in receipt(period: period, provider: provider, now: now) {
            lines.append(["Resumo", provider, "", "", value.currency, "Equivalente mensal atual",
                          money(value.monthlyKnownPlans > 0 ? value.monthlyCents : nil),
                          state(known: value.monthlyKnownPlans, unknown: value.monthlyUnknownPlans, empty: "Sem plano ativo"),
                          "", "Mensal equivalente", UsageDay.string(now), "", "", ""])
            lines.append(["Resumo", provider, "", "", value.currency, "Custo proporcional do período",
                          money(value.proportionalKnownPlans > 0 ? value.proportionalCents : nil),
                          state(known: value.proportionalKnownPlans, unknown: value.proportionalUnknownPlans, empty: "Sem plano no período"),
                          "", "", "", UsageDay.string(period.start), UsageDay.string(period.end), ""])
            lines.append(["Resumo", provider, "", "", value.currency, "Pagamentos registrados no período",
                          money(value.paymentCount > 0 ? Double(value.paidCents) : nil), value.paymentCount > 0 ? "Registrado" : "Sem pagamentos registrados",
                          "", "", "", UsageDay.string(period.start), UsageDay.string(period.end), ""])
        }
        for term in terms.filter({ $0.overlaps(period) || ($0.start <= now && ($0.end ?? .distantFuture) > now) || paidIDs.contains($0.id) }).sorted(by: { $0.start < $1.start }) {
            lines.append(["Plano", term.provider, term.name, term.account, term.currency, "Preço por conta por ciclo", money(term.cents.map(Double.init)),
                          term.cents == nil ? "A confirmar" : "Cadastrado", String(term.quantity), term.cycle.title, "", UsageDay.string(term.start), term.end.map(UsageDay.string) ?? "", ""])
        }
        for payment in payments.sorted(by: { $0.date < $1.date }) {
            guard let term = terms.first(where: { $0.id == payment.termID }), let currency = paymentCurrency(payment) else { continue }
            lines.append(["Pagamento", term.provider, term.name, term.account, currency, "Total cobrado", money(Double(payment.cents)), "Registrado",
                          "", "", UsageDay.string(payment.date), "", "", payment.evidence?.source ?? ""])
        }
        return Data(lines.map { $0.map(UsageCSV.cell).joined(separator: ",") }.joined(separator: "\r\n").utf8)
    }
    func paymentCurrency(_ payment: SubscriptionPayment) -> String? {
        payment.currency ?? document.terms.first(where: { $0.id == payment.termID })?.currency
    }
    func totalPaid(currency: String, period: DateInterval, provider: String = "Todos") -> Int {
        let ids = Set(document.terms.filter { provider == "Todos" || $0.provider == provider }.map(\.id))
        return document.payments.filter { ids.contains($0.termID) && paymentCurrency($0) == currency && $0.date >= period.start && $0.date < period.end }.reduce(0) { $0 + $1.cents }
    }
    private func save(_ value: Document) throws {
        guard writable else { throw LedgerError.unreadable }
        guard value.terms.allSatisfy(\.valid), value.payments.allSatisfy(\.valid) else { throw LedgerError.invalid }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(value); guard data.count <= 2 * 1024 * 1024 else { throw LedgerError.invalid }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        document = value; issue = nil
    }
}

enum LedgerError: LocalizedError {
    case invalid, overlap, duplicatePayment, unreadable, currencyHasPayments, evidenceConflict
    var errorDescription: String? {
        switch self {
        case .invalid: "Confira nome, conta, valor e datas."
        case .overlap: "Já existe um preço para essa conta neste período. Encerre a faixa anterior ou use outro apelido de conta."
        case .duplicatePayment: "Esse pagamento já foi registrado nesta data."
        case .unreadable: "O arquivo de assinaturas precisa ser recuperado antes de salvar."
        case .currencyHasPayments: "A moeda deste período já tem pagamentos. Encerre a faixa e crie outra na nova moeda."
        case .evidenceConflict: "Este comprovante já foi registrado com dados diferentes. Confira o pagamento original."
        }
    }
}

enum UsageCSV {
    static func cell(_ text: String) -> String {
        let safe = ["=", "+", "-", "@", "\t", "\r"].contains(where: { text.hasPrefix($0) }) ? "'" + text : text
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    static func rows(_ rows: [TokenUsageRow], prices: [ModelPrice]) -> Data {
        let header = "Dia UTC,Máquina,Projeto,Provedor,Modelo,Entrada,Saída,Cache lido,Cache criado,Cache 1h,Chamadas,Equivalente USD,Apuração"
        let lines = rows.map { row in
            let cost = row.apiEquivalent(prices: prices)
            return [row.day, row.machine ?? "Mac", row.project, row.provider, row.model, String(row.input), String(row.output), String(row.cacheRead), String(row.cacheWrite), String(row.cacheWrite1h), String(row.calls), cost.map { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "", cost == nil ? "Não apurado" : "Tarifa configurada"].map(cell).joined(separator: ",")
        }
        return Data(([header] + lines).joined(separator: "\r\n").utf8)
    }
}
