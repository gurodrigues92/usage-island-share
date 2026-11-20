import Charts
import SwiftUI
import UniformTypeIdentifiers

struct AnalysisFilters: View {
    @ObservedObject var analytics: UsageAnalytics
    var additionalProviders: [String] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Período UTC", selection: $analytics.filter.days) { ForEach([1, 7, 30, 90, 365], id: \.self) { Text($0 == 1 ? "Hoje" : "\($0) dias").tag($0) } }
                Picker("Provedor", selection: $analytics.filter.provider) { ForEach(["Todos"] + Array(Set(analytics.rows.map(\.provider) + additionalProviders)).sorted(), id: \.self) { Text($0).tag($0) } }
                Picker("Máquina", selection: $analytics.filter.machine) { ForEach(["Todas"] + Array(Set(analytics.rows.map { $0.machine ?? "Mac" })).sorted(), id: \.self) { Text($0).tag($0) } }
            }
            HStack {
                Picker("Modelo", selection: $analytics.filter.model) { ForEach(["Todos"] + Array(Set(analytics.rows.map(\.model))).sorted(), id: \.self) { Text($0).tag($0) } }
                TextField("Buscar projeto ou modelo", text: $analytics.filter.search)
                Button("Limpar filtros") { analytics.filter = AnalysisFilter() }
            }
            Text("Filtros compartilhados entre Recibo e Projetos · dias em UTC para comparar as máquinas.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct EconomicsView: View {
    @ObservedObject var analytics: UsageAnalytics
    @ObservedObject var ledger: SubscriptionLedger
    @ObservedObject var settings: UsageSettings
    @State private var message: String?
    private var terms: [SubscriptionTerm] { ledger.document.terms.filter { analytics.filter.provider == "Todos" || $0.provider == analytics.filter.provider } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AnalysisFilters(analytics: analytics, additionalProviders: ledger.document.terms.map(\.provider))
                let rows = analytics.filteredRows
                let technical = TechnicalCost(rows: rows, prices: settings.value.prices)
                let range = analytics.filter.interval()
                Text("Assinaturas e pagamentos").font(.title2.bold())
                Text("Os valores cadastrados abaixo independem dos modelos, tokens e tarifas de API.").font(.caption).foregroundStyle(.secondary)
                if analytics.filter.machine != "Todas" || analytics.filter.model != "Todos" || !analytics.filter.search.isEmpty {
                    Text("Planos e pagamentos seguem o provedor; o proporcional e os pagamentos seguem também o período. Máquina, modelo e busca afetam apenas o uso em API.").font(.caption).foregroundStyle(.secondary)
                }
                let receipts = ledger.receipt(period: range, provider: analytics.filter.provider)
                if ledger.document.terms.isEmpty {
                    ContentUnavailableView("Cadastre o que você paga", systemImage: "creditcard", description: Text("Na aba Assinaturas, confirme preços, datas e pagamentos. Nenhum valor é presumido a partir do plano."))
                } else if receipts.isEmpty {
                    Text("Nenhuma assinatura ou pagamento neste recorte.").foregroundStyle(.secondary)
                }
                ForEach(receipts) { receipt in SubscriptionReceiptCard(receipt: receipt) }
                Button("Exportar recibo financeiro em CSV…") {
                    do { try IslandExport.save(ledger.financialCSV(period: range, provider: analytics.filter.provider), name: "usage-island-recibo-financeiro.csv", type: .commaSeparatedText) }
                    catch { message = "Não foi possível exportar o recibo financeiro." }
                }.disabled(receipts.isEmpty)
                Text("O equivalente mensal divide planos anuais por 12 e considera a quantidade de contas ativas hoje. O proporcional usa os dias reais de cada ciclo no período escolhido. Pagamentos são os totais efetivamente registrados; essas três medidas não devem ser somadas.").font(.caption).foregroundStyle(.secondary)
                Text("Moedas são exibidas separadamente, sem conversão automática. Se a cobrança veio em outra moeda, ela aparece só na moeda efetivamente paga.").font(.caption).foregroundStyle(.secondary)
                if let issue = ledger.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
                Divider()
                Text("Equivalente em API").font(.title2.bold())
                HStack(alignment: .top, spacing: 30) {
                    metric("Seu uso custaria em API", technical.label)
                    metric("Tokens registrados", rows.reduce(0) { $0 + $1.tokens }.formatted())
                    metric("Chamadas registradas", rows.reduce(0) { $0 + $1.calls }.formatted())
                }
                Text("Equivalente técnico pelas tarifas configuradas. Não é uma fatura nem economia comprovada.").font(.caption).foregroundStyle(.secondary)
                Text("A comparação considera os planos cadastrados e os registros disponíveis. Contas não cadastradas não entram no custo das assinaturas.").font(.caption).foregroundStyle(.secondary)
                if technical.unknownRows > 0 { Label("\(technical.unknownRows) registros sem tarifa; o valor apurado é parcial.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if analytics.incomplete || analytics.issue != nil { Text(analytics.issue ?? "Coleta de tokens em andamento; o equivalente em API ainda é parcial.").font(.caption).foregroundStyle(.orange) }
                ForEach(ledger.receipt(period: range, provider: analytics.filter.provider)) { receipt in
                    if receipt.currency == "USD", receipt.proportionalCents > 0, technical.rowCount > technical.unknownRows,
                       SubscriptionTerm.permitsUSDComparison(terms: terms, rows: rows, period: range) {
                        Text((technical.unknownRows > 0 || analytics.incomplete || analytics.issue != nil ? "Pelo menos " : "") + String(format: "%.1f×", technical.dollars / (receipt.proportionalCents / 100)) + " o custo proporcional em USD")
                            .font(.title3.bold())
                    }
                }
                let daily = Dictionary(grouping: rows, by: \.day).sorted { $0.key < $1.key }.filter { group in
                    group.value.contains { $0.apiEquivalent(prices: settings.value.prices) != nil }
                }
                if !daily.isEmpty {
                    Text("Equivalente técnico por dia · USD").font(.headline)
                    Chart(daily, id: \.key) { group in
                        BarMark(x: .value("Dia UTC", group.key), y: .value("USD apurado", TechnicalCost(rows: group.value, prices: settings.value.prices).dollars)).foregroundStyle(.green)
                    }.frame(height: 180)
                } else if !rows.isEmpty {
                    Text("Gráfico de custo não apurado: cadastre tarifas em Configurações → Dados. Dias sem tarifa não são desenhados como zero.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Exportar tokens e equivalente em API em CSV…") {
                    do { try IslandExport.save(UsageCSV.rows(rows, prices: settings.value.prices), name: "usage-island-uso-api.csv", type: .commaSeparatedText) }
                    catch { message = "Não foi possível exportar." }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            }.padding(20)
        }
    }
    private func metric(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 4) { Text(value).font(.title2.bold()); Text(title).font(.caption).foregroundStyle(.secondary) } }
}

private struct SubscriptionReceiptCard: View {
    let receipt: SubscriptionReceipt
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(receipt.currency).font(.headline)
            HStack(alignment: .top, spacing: 18) {
                amount("Equivalente mensal dos planos ativos", receipt.monthlyLabel)
                amount("Custo proporcional do período", receipt.proportionalLabel)
                amount("Pagamentos registrados no período", receipt.paymentLabel)
            }
            if receipt.monthlyUnknownPlans > 0 || receipt.proportionalUnknownPlans > 0 {
                Text("Há preços de assinatura a confirmar. Os pagamentos registrados continuam sendo mostrados integralmente.").font(.caption).foregroundStyle(.orange)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
    private func amount(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title3.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SubscriptionsView: View {
    @ObservedObject var ledger: SubscriptionLedger
    @State private var adding = false
    @State private var editing: SubscriptionTerm?
    @State private var payment: SubscriptionTerm?
    @State private var ending: SubscriptionTerm?
    @State private var endDate = Date.now
    @State private var endIssue: String?
    @State private var message: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("Assinaturas e pagamentos").font(.title2.bold()); Spacer(); Button("Adicionar período de preço") { adding = true } }
                Text("Você confirma valores e datas. Uma mudança de preço encerra a faixa anterior e começa outra. Cancelar renovações aqui não cancela o contrato no provedor.").font(.callout).foregroundStyle(.secondary)
                if ledger.document.terms.isEmpty { ContentUnavailableView("Nenhuma assinatura cadastrada", systemImage: "creditcard", description: Text("Cadastre uma conta ou um grupo de contas. Valor vazio fica a confirmar; zero significa gratuito.")) }
                ForEach(ledger.document.terms.sorted { $0.start > $1.start }) { term in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(term.name).font(.headline); Text(term.provider + " · " + term.account).font(.caption).foregroundStyle(.secondary)
                            Spacer(); Text(term.cents.map { (Double($0) / 100).formatted(.currency(code: term.currency)) + " · \(term.quantity) conta(s)" } ?? "Preço a confirmar")
                        }
                        Text("\(term.cycle.title) · desde \(UsageDay.string(term.start))" + (term.end.map { " · primeiro dia sem este preço: " + UsageDay.string($0) } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                        if let renewal = term.nextRenewal() { Text("Próxima renovação prevista: " + UsageDay.string(renewal)).font(.caption) }
                        HStack {
                            Toggle("Prever próximas renovações", isOn: Binding(get: { term.renews }, set: { value in act { try ledger.setRenewal(term.id, enabled: value) } })).toggleStyle(.checkbox)
                            Spacer(); Button("Registrar pagamento") { payment = term }
                            Button("Editar") { editing = term }
                            if term.end == nil { Button("Encerrar período…") { endDate = .now; endIssue = nil; ending = term } }
                        }
                        ForEach(ledger.document.payments.filter { $0.termID == term.id }.sorted { $0.date > $1.date }) { paid in
                            Text("Pago em \(UsageDay.string(paid.date)): " + (Double(paid.cents) / 100).formatted(.currency(code: paid.currency ?? term.currency))).font(.caption).foregroundStyle(.secondary)
                            if let evidence = paid.evidence { Text("Comprovante: " + evidence.source).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                }
                if let issue = message ?? ledger.issue { Text(issue).foregroundStyle(.orange) }
            }.padding(20)
        }
        .sheet(isPresented: $adding) { SubscriptionForm(ledger: ledger) }
        .sheet(item: $editing) { term in SubscriptionForm(ledger: ledger, original: term) }
        .sheet(item: $payment) { term in PaymentForm(ledger: ledger, term: term) }
        .sheet(item: $ending) { term in
            VStack(alignment: .leading, spacing: 18) {
                Text("Encerrar \(term.name)").font(.headline)
                Text("O histórico e os pagamentos ficam preservados. Informe o primeiro dia sem acesso a esse preço.")
                DatePicker("Primeiro dia sem acesso", selection: $endDate, displayedComponents: .date)
                if let endIssue { Text(endIssue).font(.caption).foregroundStyle(.orange) }
                HStack { Button("Cancelar") { ending = nil }; Spacer(); Button("Salvar encerramento") {
                    do { try ledger.end(term.id, on: UsageDay.fromPicker(endDate)); ending = nil; endIssue = nil } catch { endIssue = error.localizedDescription }
                } }
            }.padding(24).frame(width: 440)
        }
    }
    private func act(_ action: () throws -> Void) { do { try action(); message = nil } catch { message = error.localizedDescription } }
}

private struct SubscriptionForm: View {
    @ObservedObject var ledger: SubscriptionLedger
    private let original: SubscriptionTerm?
    @Environment(\.dismiss) private var dismiss
    @State private var provider = "Codex"
    @State private var name = ""
    @State private var account = "Principal"
    @State private var amount = ""
    @State private var currency = "USD"
    @State private var quantity = 1
    @State private var cycle = BillingCycle.monthly
    @State private var start = UsageDay.calendar.startOfDay(for: .now)
    @State private var issue: String?
    init(ledger: SubscriptionLedger, original: SubscriptionTerm? = nil) {
        self.ledger = ledger; self.original = original
        _provider = State(initialValue: original?.provider ?? "Codex")
        _name = State(initialValue: original?.name ?? "")
        _account = State(initialValue: original?.account ?? "Principal")
        _amount = State(initialValue: original?.cents.map { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double($0) / 100) } ?? "")
        _currency = State(initialValue: original?.currency ?? "USD")
        _quantity = State(initialValue: original?.quantity ?? 1)
        _cycle = State(initialValue: original?.cycle ?? .monthly)
        _start = State(initialValue: original.map { UsageDay.pickerDate($0.start) } ?? .now)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(original == nil ? "Novo período de preço" : "Corrigir período de preço").font(.title2.bold())
            Form {
                Picker("Provedor", selection: $provider) { ForEach(["Claude", "Codex", "SuperGrok", "OpenCode", "OpenRouter", "Outro"], id: \.self) { Text($0).tag($0) } }
                TextField("Nome do plano", text: $name)
                TextField("Apelido da conta ou grupo", text: $account)
                HStack { TextField("Valor por conta (vazio = a confirmar)", text: $amount); Picker("Moeda", selection: $currency) { ForEach(["USD", "BRL", "EUR"], id: \.self) { Text($0).tag($0) } } }
                Stepper("Quantidade de contas: \(quantity)", value: $quantity, in: 1...100)
                Picker("Ciclo", selection: $cycle) { ForEach(BillingCycle.allCases, id: \.self) { Text($0.title).tag($0) } }
                DatePicker("Início do preço/ciclo", selection: $start, displayedComponents: .date)
            }
            if let issue { Text(issue).foregroundStyle(.orange).font(.caption) }
            HStack { Button("Cancelar") { dismiss() }; Spacer(); Button("Salvar") { save() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 520)
    }
    private func save() {
        let text = amount.trimmingCharacters(in: .whitespaces)
        guard text.isEmpty || Self.cents(text) != nil else { issue = "Informe um valor válido, sem separador de milhar."; return }
        do {
            var term = SubscriptionTerm(provider: provider, name: name.trimmingCharacters(in: .whitespaces), account: account.trimmingCharacters(in: .whitespaces), currency: currency, cents: Self.cents(text), quantity: quantity, cycle: cycle, start: UsageDay.fromPicker(start))
            if let original { term.id = original.id; term.end = original.end; term.renews = original.renews; try ledger.update(term) }
            else { try ledger.add(term) }
            dismiss()
        }
        catch { issue = error.localizedDescription }
    }
    static func cents(_ text: String) -> Int? {
        let value = text.replacingOccurrences(of: ",", with: ".")
        guard value.range(of: "^[0-9]+(?:\\.[0-9]{1,2})?$", options: .regularExpression) != nil,
              let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), decimal <= 10_000_000 else { return nil }
        return NSDecimalNumber(decimal: decimal * 100).intValue
    }
}

private struct PaymentForm: View {
    @ObservedObject var ledger: SubscriptionLedger
    let term: SubscriptionTerm
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var date = Date.now
    @State private var currency: String?
    @State private var issue: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Pagamento de \(term.name)").font(.headline)
            Text("Informe o total e a moeda realmente cobrados, incluindo todas as contas. Isso não cria uma cobrança no provedor.").font(.callout)
            Picker("Moeda da cobrança", selection: Binding(get: { currency ?? term.currency }, set: { currency = $0 })) {
                ForEach(["USD", "BRL", "EUR"], id: \.self) { Text($0).tag($0) }
            }
            TextField("Total pago", text: $amount)
            DatePicker("Data do pagamento", selection: $date, displayedComponents: .date)
            if let issue { Text(issue).font(.caption).foregroundStyle(.orange) }
            HStack { Button("Cancelar") { dismiss() }; Spacer(); Button("Registrar pagamento") {
                guard let cents = SubscriptionForm.cents(amount) else { issue = "Confira o valor do pagamento."; return }
                do { try ledger.addPayment(.init(termID: term.id, date: UsageDay.fromPicker(date), cents: cents, currency: currency ?? term.currency)); dismiss() } catch { issue = error.localizedDescription }
            } }
        }.padding(24).frame(width: 440)
    }
}
