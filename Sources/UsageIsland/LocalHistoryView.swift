import Combine
import Foundation
import SwiftUI

struct LocalSession: Decodable, Identifiable, Equatable, Sendable {
    var id: String
    var file: String
    var provider: String
    var project: String
    var model: String
    var title: String
    var startedAt: String
    var updatedAt: String
}
struct ReplayEvent: Decodable, Identifiable, Sendable {
    var id: String
    var kind: String
    var text: String
    var timestamp: String?
    var status: String
    var title: String {
        switch kind { case "user": "Você"; case "assistant": "Assistente"; case "read": "Leitura"; case "edit": "Edição"; case "command": "Comando"; case "test": "Teste"; default: "Ferramenta" }
    }
    var result: String {
        switch status { case "success": "Saída 0 confirmada"; case "failed": "Falha registrada"; case "pending": "Sem resultado no recorte"; case "received": "Retorno recebido · sucesso não confirmado"; default: "Registro local" }
    }
}

@MainActor final class LocalSessionHistory: ObservableObject {
    @Published private(set) var sessions: [LocalSession] = []
    @Published private(set) var events: [ReplayEvent] = []
    @Published private(set) var enabled = false
    @Published private(set) var loading = false
    @Published private(set) var reading = false
    @Published private(set) var limited = false
    @Published private(set) var detailLimited = false
    @Published private(set) var issue: String?
    private var generation = 0
    func disable() { generation += 1; enabled = false; sessions = []; events = []; loading = false; reading = false; issue = nil }
    func refresh() async {
        guard !loading, !reading else { return }; enabled = true; loading = true; generation += 1; let request = generation
        defer { if generation == request { loading = false } }
        struct Index: Decodable { var sessions: [LocalSession]; var limited: Bool }
        guard let data = await Self.run([]), let result = try? JSONDecoder().decode(Index.self, from: data) else {
            if generation == request { issue = "Não foi possível ler o histórico local; os dados anteriores foram preservados." }; return
        }
        guard generation == request else { return }
        sessions = result.sessions; limited = result.limited; issue = nil
    }
    func read(_ session: LocalSession) async {
        guard enabled, !loading else { return }
        generation += 1; let request = generation; reading = true; events = []; detailLimited = false
        defer { if generation == request { reading = false } }
        struct Detail: Decodable { var events: [ReplayEvent]; var limited: Bool }
        guard let data = await Self.run(["--detail", session.file]), let result = try? JSONDecoder().decode(Detail.self, from: data) else {
            if generation == request { issue = "Não foi possível abrir esta sessão." }; return
        }
        guard generation == request, enabled else { return }
        events = result.events; detailLimited = result.limited; issue = nil
    }
    private static func run(_ arguments: [String]) async -> Data? {
        guard let script = IslandResource.url("session-history", extension: "py"),
              let python = ["/opt/homebrew/bin/python3", "/usr/bin/python3", "/usr/local/bin/python3"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        return await Task.detached(priority: .utility) {
            guard let value = BoundedProcess.run(executable: python, arguments: [script.path] + arguments, timeout: 35, outputLimit: 4 * 1024 * 1024), value.status == 0 else { return nil as Data? }
            return value.output
        }.value
    }
}

struct LocalHistoryView: View {
    @ObservedObject var library: LocalSessionHistory
    @State private var search = ""
    @State private var provider = "Todos"
    @State private var selection: LocalSession?
    private var sessions: [LocalSession] {
        library.sessions.filter { (provider == "Todos" || $0.provider == provider) && (search.isEmpty || ($0.title + " " + $0.project + " " + $0.model).localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Conversas locais e replay").font(.title2.bold()); Spacer()
                if library.loading { ProgressView().controlSize(.small) }
                Button(library.enabled ? "Atualizar lista" : "Ler histórico local") { Task { await library.refresh() } }.disabled(library.loading || library.reading)
                if library.enabled { Button("Limpar da memória") { selection = nil; library.disable() } }
            }
            Text("Leitura sob demanda de Claude Code e Codex. Títulos e mensagens ficam só na memória do app; padrões conhecidos de credenciais são ocultados. Os arquivos originais não são alterados.").font(.caption).foregroundStyle(.secondary)
            HStack { TextField("Buscar conversa, projeto ou modelo", text: $search); Picker("Provedor", selection: $provider) { ForEach(["Todos", "Claude", "Codex"], id: \.self) { Text($0).tag($0) } }; Text("\(sessions.count) sessões").font(.caption) }
            if sessions.isEmpty { ContentUnavailableView(library.enabled ? "Nenhuma sessão neste filtro" : "Histórico ainda não carregado", systemImage: "text.bubble", description: Text("Use Ler histórico local para consultar até 100 arquivos recentes. Conteúdo de conversas não entra nos relatórios de tokens ou pacotes entre máquinas.")) }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(sessions) { session in
                        Button { selection = session; Task { await library.read(session) } } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(session.title).font(.headline).lineLimit(2); Spacer(); Image(systemName: "play.rectangle") }
                                Text(session.provider + " · " + session.project + " · " + session.model).font(.caption).foregroundStyle(.secondary)
                                Text((UsageDates.parse(session.updatedAt) ?? .distantPast).formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).disabled(library.loading)
                    }
                }
            }
            if library.limited { Text("Mostrando até 100 arquivos recentes; a lista não representa todo o histórico.").font(.caption).foregroundStyle(.orange) }
            if let issue = library.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
        }.padding(20)
        .sheet(item: $selection) { session in SessionReplayView(session: session, library: library) }
    }
}

struct SessionReplayView: View {
    let session: LocalSession
    @ObservedObject var library: LocalSessionHistory
    @Environment(\.dismiss) private var dismiss
    @State private var playing = false
    @State private var position = 0.0
    @State private var speed = 1
    private let timer = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()
    private var visible: [ReplayEvent] { Array(library.events.prefix(Int(position))) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { VStack(alignment: .leading) { Text(session.title).font(.headline).lineLimit(2); Text(session.provider + " · " + session.project).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Fechar") { dismiss() } }
            Text("Reconstituição de registros · nenhum comando é executado novamente. Resultados ausentes não contam como sucesso. Raciocínio interno e blocos thinking ficam fora desta visualização.").font(.caption).foregroundStyle(.secondary)
            if library.reading { ProgressView("Lendo fonte local…") }
            else {
                HStack {
                    Button(playing ? "Pausar" : "Reproduzir") { if position >= Double(library.events.count) { position = 0 }; playing.toggle() }
                    Button("Do início") { position = 0; playing = false }
                    Button("Mostrar tudo") { position = Double(library.events.count); playing = false }
                    Picker("Velocidade", selection: $speed) { ForEach([1, 2, 4], id: \.self) { Text("\($0)×").tag($0) } }.frame(width: 130)
                    Slider(value: $position, in: 0...Double(max(1, library.events.count)), step: 1)
                    Text("\(Int(position))/\(library.events.count)").monospacedDigit().font(.caption)
                }
                HStack(spacing: 20) {
                    Text("\(visible.filter { $0.kind == "user" }.count) mensagens suas")
                    Text("\(visible.filter { ["read", "edit", "command", "tool"].contains($0.kind) }.count) ações")
                    Text("\(visible.filter { $0.kind == "test" && $0.status == "success" }.count) execuções de teste com saída 0")
                }.font(.caption)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(visible) { event in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack { Text(event.title).bold(); Spacer(); Text(event.timestamp.flatMap(UsageDates.parse)?.formatted(date: .omitted, time: .standard) ?? "Horário não registrado").foregroundStyle(.secondary) }.font(.caption)
                                    Text(event.text).font(.system(size: 12, design: event.kind == "user" || event.kind == "assistant" ? .default : .monospaced)).textSelection(.enabled)
                                    Text(event.result).font(.caption).foregroundStyle(event.status == "failed" ? .orange : .secondary)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10)).id(event.id)
                            }
                        }
                    }.onChange(of: position) { _, _ in if playing, let last = visible.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            if library.detailLimited { Text("Visualização parcial: limite de leitura atingido ou registros grandes/inválidos omitidos. Resultados ausentes permanecem desconhecidos.").font(.caption).foregroundStyle(.orange) }
            if let issue = library.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
        }.padding(22).frame(width: 820, height: 650)
        .onChange(of: library.events.count) { _, value in position = Double(value); playing = false }
        .onReceive(timer) { _ in if playing { position = min(Double(library.events.count), position + Double(speed)); if position >= Double(library.events.count) { playing = false } } }
    }
}
