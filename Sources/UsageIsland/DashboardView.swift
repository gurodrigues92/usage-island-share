import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct DashboardView: View {
    @ObservedObject var model: IslandModel
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Seu uso de IA").font(.title2.bold())
                    Text("Cotas da conta, histórico e atividade local").foregroundStyle(.secondary)
                }
                Spacer(); Button("Atualizar") { model.refreshNow(); Task { await model.analytics.refresh(prices: model.settings.value.prices, force: true, complete: true) } }
                Button { model.onSettings?() } label: { Label("Configurações", systemImage: "gearshape") }
            }.padding(.horizontal, 20).padding(.top, 18)
            TabView(selection: $model.dashboardTab) {
                OverviewView(model: model).tabItem { Label("Agora", systemImage: "gauge.with.dots.needle.50percent") }.tag(0)
                QuotaHistoryView(model: model, history: model.history, isActive: model.dashboardTab == 1).tabItem { Label("Histórico", systemImage: "chart.xyaxis.line") }.tag(1)
                EconomicsView(analytics: model.analytics, ledger: model.subscriptions, settings: model.settings).tabItem { Label("Recibo", systemImage: "receipt") }.tag(2)
                SubscriptionsView(ledger: model.subscriptions).tabItem { Label("Assinaturas", systemImage: "creditcard") }.tag(3)
                TokenProjectsView(model: model, analytics: model.analytics, isActive: model.dashboardTab == 4).tabItem { Label("Projetos", systemImage: "folder") }.tag(4)
                SessionsView(model: model).tabItem { Label("Sessões", systemImage: "terminal") }.tag(5)
                LocalHistoryView(library: model.localHistory).tabItem { Label("Conversas", systemImage: "text.bubble") }.tag(6)
            }.padding(.horizontal, 16).padding(.bottom, 16)
        }.frame(minWidth: 760, idealWidth: 900, minHeight: 600, idealHeight: 730)
    }
}

/// AppKit can lay out inactive TabView children. Keep the owning view (and its
/// picker state) mounted, but build expensive charts only for the selected tab.
struct ActiveDashboardContent<Content: View>: View {
    let isActive: Bool
    @ViewBuilder var content: () -> Content
    var body: some View {
        if isActive { content() }
        else { Color.clear }
    }
}

struct OverviewView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var history: UsageHistory
    @ObservedObject var settings: UsageSettings
    init(model: IslandModel) { self.model = model; history = model.history; settings = model.settings }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let room = model.mostRoom {
                    let left = 100 - (room.windows.map(\.percent).max() ?? 100)
                    Label("\(room.displayName) tem mais folga agora: \(Int(left))% na janela mais restrita", systemImage: "sparkles")
                        .font(.headline).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                } else { Text("Aguardando leituras recentes para comparar a disponibilidade.").foregroundStyle(.secondary) }
                ForEach(model.allSnapshots) { snapshot in
                    let remaining = settings.value.showsRemaining(for: snapshot.id)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label { Text(snapshot.displayName) } icon: {
                                ProviderMark(source: snapshot.source, customSymbol: snapshot.customSymbol).frame(width: 18, height: 18)
                            }.font(.headline)
                            Spacer(); Text(snapshot.statusText()).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(remaining ? "Cota restante" : "Cota usada").font(.caption).foregroundStyle(.secondary)
                        if let balance = snapshot.balanceText { Text(balance).font(.callout) }
                        ForEach(snapshot.windows) { window in
                            let displayedPercent = remaining ? 100 - window.percent : window.percent
                            HStack {
                                Text(window.title).frame(width: 155, alignment: .leading)
                                ProgressView(value: displayedPercent, total: 100).tint(window.blocked || window.percent >= 90 ? .orange : .green)
                                Text(UsageValidation.display(displayedPercent, rounded: snapshot.source == .grok)).monospacedDigit().frame(width: 50)
                                TimelineView(.periodic(from: .now, by: 30)) { context in
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(window.resetText(now: context.date))
                                        if let reset = window.resetsAt {
                                            Text(reset.formatted(date: .numeric, time: .shortened))
                                                .help("Data e hora locais da renovação informada pelo provedor")
                                        }
                                    }.font(.caption).foregroundStyle(.secondary).frame(width: 180, alignment: .trailing)
                                }
                            }
                            if settings.value.forecast, let forecast = history.forecast(for: snapshot, windowID: window.id) {
                                ForecastCaption(forecast: forecast, windowTitle: window.title)
                            }
                        }
                        if snapshot.windows.isEmpty { Text(snapshot.percentUsed == nil ? snapshot.resetText : Self.displayPercent(for: snapshot, remaining: remaining) + " · " + snapshot.fidelity.etiqueta).foregroundStyle(.secondary) }
                        Text(snapshot.lastReadText).font(.caption).foregroundStyle(.secondary)
                        if let note = snapshot.quotaSourceNote { Text(note).font(.caption).foregroundStyle(.secondary) }
                        if let split = snapshot.hostSplit { Text(split.resumo + " · tokens medidos em \(split.dias) dias" + (split.warning.map { " · " + $0 } ?? "")).font(.caption).foregroundStyle(.secondary) }
                    }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                }
                Text("Cada provedor indica se a porcentagem é usada ou restante. Ajuste em Configurações → Barra.").font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }
    }
    static func displayPercent(for snapshot: UsageSnapshot, remaining: Bool) -> String {
        UsageValidation.display(remaining ? snapshot.ringPercent.map { 100 - $0 } : snapshot.ringPercent, rounded: snapshot.source == .grok)
    }
}

struct ForecastCaption: View {
    let forecast: QuotaForecast
    var windowTitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let out = forecast.runsOutAt {
                Label("Pode acabar antes do reset, por volta de " + out.formatted(date: .abbreviated, time: .shortened), systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)
            } else { Label("No ritmo recente, a cota deve durar até o reset", systemImage: "clock.badge.checkmark") }
            Text("\(windowTitle.map { "Previsão · " + $0 } ?? "Previsão desta janela") · \(forecast.pointsPerHour, specifier: "%.1f") pontos/h · confiança \(forecast.confidence.rawValue.lowercased())")
                .font(.caption).foregroundStyle(.secondary)
        }.font(.callout)
    }
}

struct QuotaHistoryView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var history: UsageHistory
    var isActive = true
    @State private var entryID = ""
    @State private var windowID = ""
    @State private var days = 7
    var body: some View {
        ActiveDashboardContent(isActive: isActive) { activeContent }
    }
    @ViewBuilder private var activeContent: some View {
        let selection = QuotaHistorySelection(entryIDs: model.allSnapshots.map(\.id), samples: history.samples,
                                             preferredEntryID: entryID, preferredWindowID: windowID, days: days)
        let points = selection.points
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Conta", selection: Binding(get: { selection.entryID }, set: { entryID = $0; windowID = "" })) {
                    ForEach(model.allSnapshots) { Text($0.displayName).tag($0.id) }
                }
                Picker("Janela", selection: Binding(get: { selection.windowID }, set: { windowID = $0 })) { ForEach(selection.windows) { Text($0.title).tag($0.id) } }
                Picker("Período", selection: $days) { Text("24 horas").tag(1); Text("7 dias").tag(7); Text("30 dias").tag(30) }
            }
            if points.isEmpty {
                ContentUnavailableView("O histórico começa com as novas leituras", systemImage: "chart.xyaxis.line",
                                       description: Text("As porcentagens antigas não podem ser reconstruídas pelos registros de tokens."))
            } else {
                Chart(points) { point in
                    LineMark(x: .value("Leitura", point.sample.capturedAt), y: .value("Uso", point.sample.window.percent), series: .value("Trecho", point.segment))
                        .interpolationMethod(.linear).foregroundStyle(.green)
                    PointMark(x: .value("Leitura", point.sample.capturedAt), y: .value("Uso", point.sample.window.percent)).symbolSize(14).foregroundStyle(.green)
                }.chartYScale(domain: 0...100).chartYAxisLabel("Cota usada (%)").frame(minHeight: 220)
                Text("\(points.count) leituras · lacunas e novas concessões interrompem a linha · últimos dados: " + (points.last?.sample.capturedAt.formatted() ?? "—"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let issue = history.issue { Text(issue).foregroundStyle(.orange) }
            Text("Armazenado neste Mac. Reset e redução da cota são preservados no histórico.").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(20)
    }
}

struct TokenProjectsView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var analytics: UsageAnalytics
    var isActive = true
    @State private var dimension = "Projeto"
    @State private var selectedProject: String?
    @State private var message: String?
    private var rows: [TokenUsageRow] { analytics.filteredRows }
    struct Group: Identifiable { var id: String; var tokens: Int; var calls: Int; var cost: Double; var unknown: Int }
    private var groups: [Group] {
        Dictionary(grouping: rows, by: { dimension == "Modelo" ? $0.model : dimension == "Provedor" ? $0.provider : dimension == "Máquina" ? ($0.machine ?? "Mac") : $0.project })
            .map { key, rows in
                let priced = rows.compactMap { $0.apiEquivalent(prices: model.settings.value.prices) }
                return Group(id: key, tokens: rows.reduce(0) { $0 + $1.tokens }, calls: rows.reduce(0) { $0 + $1.calls }, cost: priced.reduce(0,+), unknown: rows.count - priced.count)
            }.sorted { $0.tokens > $1.tokens }
    }
    var body: some View {
        ActiveDashboardContent(isActive: isActive) { activeContent }
    }
    @ViewBuilder private var activeContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            AnalysisFilters(analytics: analytics)
            HStack {
                Picker("Agrupar por", selection: $dimension) { ForEach(["Projeto", "Modelo", "Provedor", "Máquina"], id: \.self) { Text($0).tag($0) } }
                Spacer()
                if analytics.refreshing { ProgressView().controlSize(.small) }
                Button(analytics.incomplete ? "Concluir coleta" : "Atualizar dados") { Task { await analytics.refresh(prices: model.settings.value.prices, force: true, complete: true) } }.disabled(analytics.refreshing)
                if analytics.completingCollection { Button("Parar após lote") { analytics.cancelCollection() } }
                Button("CSV…") {
                    do { try IslandExport.save(UsageCSV.rows(rows, prices: model.settings.value.prices), name: "usage-island-projetos.csv", type: .commaSeparatedText) }
                    catch { message = "Não foi possível exportar a análise." }
                }
            }
            HStack {
                Button("Exportar este Mac · 7 dias…") {
                    do { try IslandExport.save(analytics.portableData(), name: "usage-island-coleta-7-dias.json", type: .json) }
                    catch { message = "Não foi possível exportar a coleta." }
                }.disabled(!analytics.canExportPortableUsage)
                    .help(analytics.portableExportIssue ?? "Exportar a coleta local dos últimos 7 dias")
                Button("Importar outro Mac…") {
                    let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        do { let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0; guard size <= 4 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }; try analytics.importData(Data(contentsOf: url)); message = "Coleta importada. Repetições foram deduplicadas pela máquina e dia." }
                        catch { message = "Pacote inválido, muito grande ou pertencente a este mesmo Mac." }
                    }
                }
                Text("Só contadores e nomes de projetos/modelos; sem mensagens. Não reexporta importados ou VPS.").font(.caption).foregroundStyle(.secondary)
            }
            if let progress = analytics.progress {
                HStack { if analytics.refreshing, let fraction = progress.fraction { ProgressView(value: fraction).frame(width: 150) }; Text(progress.label).font(.caption).monospacedDigit() }
            }
            if let message = analytics.collectionMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let issue = analytics.portableExportIssue { Text(issue).font(.caption).foregroundStyle(.secondary) }
            let total = rows.reduce(0) { $0 + $1.tokens }
            let cached = rows.reduce(0) { $0 + $1.cacheRead }
            HStack(spacing: 28) {
                stat("Tokens registrados", value: total.formatted())
                stat("Chamadas registradas", value: rows.reduce(0) { $0 + $1.calls }.formatted())
                stat("Leitura de cache", value: total > 0 ? String(format: "%.1f%%", Double(cached) / Double(total) * 100) : "—")
            }
            if groups.isEmpty { ContentUnavailableView("Aguardando registros locais", systemImage: "folder", description: Text("O coletor lê apenas contadores e metadados dos registros das CLIs.")) }
            else {
                Chart(Array(groups.prefix(8))) { group in
                    BarMark(x: .value("Tokens", group.tokens), y: .value(dimension, group.id)).foregroundStyle(.green)
                }.frame(height: 185)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(groups) { group in
                            HStack { Text(group.id).lineLimit(1); Spacer(); Text(group.tokens.formatted() + " tokens").monospacedDigit()
                                Text(group.unknown > 0 ? (group.cost > 0 ? String(format: "US$ %.2f + sem preço", group.cost) : "Sem preço") : String(format: "US$ %.2f", group.cost))
                                    .font(.caption).foregroundStyle(.secondary).frame(width: 155, alignment: .trailing)
                                if dimension == "Projeto" { Button("Detalhar") { selectedProject = group.id } }
                            }
                            Divider()
                        }
                    }
                }
            }
            if analytics.incomplete { Label("Leitura inicial em andamento; os próximos ciclos continuam de onde pararam.", systemImage: "hourglass").font(.caption).foregroundStyle(.orange) }
            if let issue = analytics.issue ?? message { Text(issue).font(.caption).foregroundStyle(.orange) }
            if let date = analytics.vpsUpdatedAt { Text("VPS: última coleta " + date.formatted()).font(.caption).foregroundStyle(.secondary) }
            Text("Períodos em UTC · registros por máquina com cache separado · US$ é equivalente em API, com os preços das configurações.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20)
        .sheet(isPresented: Binding(get: { selectedProject != nil }, set: { if !$0 { selectedProject = nil } })) {
            if let selectedProject { ProjectModelsView(project: selectedProject, rows: rows.filter { $0.project == selectedProject }, prices: model.settings.value.prices) }
        }
    }
    private func stat(_ title: String, value: String) -> some View { VStack(alignment: .leading, spacing: 3) { Text(value).font(.title3.bold()); Text(title).font(.caption).foregroundStyle(.secondary) } }
}

struct ProjectModelsView: View {
    let project: String
    let rows: [TokenUsageRow]
    let prices: [ModelPrice]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(project).font(.title2.bold()); Spacer(); Button("Fechar") { dismiss() } }
            Text("Modelo e provedor no recorte selecionado · " + TechnicalCost(rows: rows, prices: prices).label).foregroundStyle(.secondary)
            ScrollView {
                let groups = Dictionary(grouping: rows, by: { $0.provider + " · " + $0.model }).sorted { $0.key < $1.key }
                ForEach(groups, id: \.key) { group in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(group.key).font(.headline)
                        Text(group.value.reduce(0) { $0 + $1.tokens }.formatted() + " tokens · " + group.value.reduce(0) { $0 + $1.calls }.formatted() + " chamadas · " + TechnicalCost(rows: group.value, prices: prices).label)
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            Button("Exportar modelos deste projeto em CSV…") { try? IslandExport.save(UsageCSV.rows(rows, prices: prices), name: "usage-island-projeto.csv", type: .commaSeparatedText) }
            Text("Chamadas são registros de consumo, não quantidade de conversas.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 650, height: 500)
    }
}

struct SessionsView: View {
    @ObservedObject var model: IslandModel
    @State private var issue: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(model.allSnapshots) { snapshot in
                    if let activity = model.claudeActivity[snapshot.id] {
                        Text(snapshot.displayName).font(.headline)
                        ForEach(activity.sessions) { session in
                            HStack {
                                Image(systemName: session.state == .busy ? "gearshape.2" : session.state == .waiting ? "person.fill.questionmark" : "checkmark.circle").foregroundStyle(SessionRow.cor(session.state))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.name).lineLimit(1)
                                    Text(session.detail + " · " + (session.state == .busy ? "trabalhando" : session.state == .waiting ? "esperando você" : "em repouso") + (session.isHeuristic ? " · estimado" : ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Button("Abrir aplicação") { model.openSession(session) }
                            }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                if model.claudeActivity.values.allSatisfy({ $0.sessions.isEmpty }) { ContentUnavailableView("Nenhuma sessão detectada", systemImage: "terminal", description: Text("As sessões aparecem quando suas ferramentas publicam atividade local.")) }
                Divider()
                Text("OpenCode").font(.headline)
                Text("A integração local registra só nome, estado e processo da sessão. Ela começa a funcionar nas próximas sessões do OpenCode.").font(.caption).foregroundStyle(.secondary)
                Button("Instalar integração de sessões do OpenCode") {
                    do { try OpenCodeActivityBridge.install(); issue = "Integração instalada. As próximas sessões do OpenCode carregarão o monitor." }
                    catch { issue = "Não foi possível instalar a integração local." }
                }
                if let issue { Text(issue).font(.caption).foregroundStyle(.secondary) }
                Text("O clique abre a aplicação da sessão. A seleção de uma aba depende do suporte da ferramenta.").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }
    }
}

enum OpenCodeActivityBridge {
    static func install(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        guard let source = IslandResource.url("usage-island-opencode", extension: "js") else { throw CocoaError(.fileNoSuchFile) }
        let directory = home.appendingPathComponent(".config/opencode/plugins")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("usage-island-activity.js")
        if FileManager.default.fileExists(atPath: destination.path) {
            let backup = home.appendingPathComponent(".cache/usage-island/backups")
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: destination, to: backup.appendingPathComponent("opencode-" + UUID().uuidString + ".js"))
        }
        try Data(contentsOf: source).write(to: destination, options: .atomic)
    }
}
