import AppKit
import Combine
import Foundation
import SwiftUI

enum UsageSource: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case codex = "Codex"
    case grok = "SuperGrok"
    case opencode = "OpenCode"

    var id: Self { self }

    var tint: Color {
        switch self {
        case .claude: .orange
        case .codex: Color(red: 0.10, green: 0.94, blue: 0.60)
        case .grok: Color(red: 0.45, green: 0.56, blue: 1.00)
        case .opencode: Color(red: 0.97, green: 0.86, blue: 0.10)
        }
    }

    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .grok: "bolt.fill"
        case .opencode: "terminal.fill"
        }
    }

    var displayName: String { rawValue }
}

extension Color {
    /// Track behind rings and bars — sampled from the reference (#2E2E2E).
    static let islandTrack = Color(red: 0.18, green: 0.18, blue: 0.18)

    /// Ambar do "esperando voce". Fica fora da escala verde/amarelo/vermelho de propriedade:
    /// aquela escala diz quanto da cota foi gasta, e este anel nao fala de cota nenhuma.
    /// E a unica cor que sobrevive ao preto e branco da ilha encolhida, porque e o unico
    /// estado em que a ilha esta pedindo alguma coisa.
    static let islandWatch = Color(red: 1.00, green: 0.72, blue: 0.20)

    /// Colour encodes urgency, not the provider: green → yellow → red-orange.
    static func usageLevel(_ percent: Double?) -> Color {
        guard let percent else { return .white.opacity(0.35) }
        switch percent {
        case ..<45: return Color(red: 0.00, green: 1.00, blue: 0.545)   // #00FF8B
        case ..<70: return Color(red: 0.953, green: 0.992, blue: 0.00)  // #F3FD00
        default:    return Color(red: 1.00, green: 0.251, blue: 0.004)  // #FF4001
        }
    }
}

enum UsageSyncState: Equatable {
    case loading
    case live
    case manual
    case unavailable
    case failed

    var label: String {
        switch self {
        case .loading: "Atualizando…"
        case .live: "Atualizado automaticamente"
        case .manual: "Atualização manual necessária"
        case .unavailable: "Conector ainda não configurado"
        case .failed: "Leitura indisponível; nova tentativa automática"
        }
    }
}

/// De quem e o numero. O card nunca deve vestir uma estimativa de fato publicado pelo
/// fornecedor: o SuperGrok digitado na mao e o Claude vindo do endpoint da Anthropic
/// apareciam iguais na tela, e essa e a diferenca que decide se da para confiar no anel.
enum UsageFidelity: String, Equatable {
    /// Numero do proprio fornecedor.
    case oficial
    /// Deduzido por nos de algum sinal indireto.
    case derivado
    /// Digitado a mao.
    case manual

    var etiqueta: String {
        switch self {
        case .oficial: "número da fonte"
        case .derivado: "deduzido daqui"
        case .manual: "digitado à mão"
        }
    }
}

/// Uma janela de limite alem das duas que o card ja desenha. Hoje so o Claude tem: os
/// tetos semanais por modelo, que antes ficavam invisiveis atras do total.
struct UsageWindowLine: Identifiable, Equatable {
    let id: String
    let title: String
    let percent: Double
    let reset: String
}

struct UsageSnapshot: Identifiable, Equatable {
    /// O tipo de provedor: e ele que da a marca, a cor e o simbolo.
    let source: UsageSource
    /// Qual conta, quando ha mais de uma do mesmo provedor. Nil e a conta padrao.
    ///
    /// A identidade do anel deixou de ser o `UsageSource` por causa disto: duas contas do
    /// Claude sao dois aneis com a mesma marca, e um enum nao consegue ser duas coisas.
    var accountSlug: String? = nil
    var percentUsed: Double?
    var sessionPercent: Double?
    var resetText: String
    var updatedAt: Date
    var syncState: UsageSyncState
    /// Names the window the main percentage refers to, when the provider tells us which one
    /// is binding. Nil falls back to the label the card picks from the provider.
    var limitLabel: String? = nil
    /// Reset of the window `limitLabel` names, when it differs from the session's.
    var limitResetText: String? = nil
    /// Names the secondary bar when it is not a session — the Grok card's second window is a
    /// rate limit on a different plane, and calling it "Sessão atual" would be a lie.
    var sessionLabel: String? = nil
    /// Ver `UsageWindowLine`.
    var extraWindows: [UsageWindowLine] = []
    var fidelity: UsageFidelity = .derivado
    /// Repartição do consumo entre as maquinas, quando ha rastro para deduzi-la nos dois
    /// hosts. Ver `HostSplit`. Nulo em provedor sem rastro contavel — inventar um recorte
    /// seria mostrar um numero que ninguem mediu.
    var hostSplit: HostSplit? = nil

    var id: String { accountSlug.map { "\(source.rawValue)-\($0)" } ?? source.rawValue }
    var displayName: String { accountSlug.map { "\(source.displayName) (\($0))" } ?? source.displayName }
    var displayPercent: String { percentUsed.map { "\(Int($0))%" } ?? "—" }

    /// Publish a coherent weekly reading. A failed weekly request must not reuse the
    /// chat's bar with the weekly error as its remaining/reset label.
    mutating func applyGrokReading(_ reading: GrokUsageReader.Reading) {
        guard source == .grok else { return }
        limitLabel = "Limite semanal"
        extraWindows = []
        guard let weekly = reading.weekly else {
            percentUsed = nil
            sessionPercent = nil
            sessionLabel = nil
            resetText = "Não foi possível ler o uso semanal. Nova tentativa automática em 1 min."
            limitResetText = nil
            syncState = .failed
            return
        }
        percentUsed = weekly.percentUsed
        sessionPercent = reading.web?.percentUsed
        sessionLabel = reading.web?.windowLabel
        limitResetText = weekly.resetText
        resetText = reading.web.map { "\($0.remaining) de \($0.total) restantes" } ?? weekly.resetText
        updatedAt = reading.updatedAt
        syncState = .live
        fidelity = .oficial
    }

    /// Quantas barras o card vai desenhar — e o que dita a altura dele.
    var cardRows: Int {
        (sessionPercent == nil ? 0 : 1) + (percentUsed == nil ? 0 : 1) + extraWindows.count
    }
}

@MainActor
final class IslandModel: ObservableObject {
    @Published var selected: String? = nil
    @Published var isExpanded = false
    /// Idle state: rings only, no numbers, so the island stays out of the way of whatever
    /// is on screen. It grows on hover and shrinks back `idleDelay` after the pointer
    /// leaves — never while a detail card is open.
    @Published private(set) var isCompact = true
    private var isHovering = false
    private var idleTimer: Timer?
    private let idleDelay: TimeInterval = 8
    /// Card aberto ganha mais folga: ele foi aberto de proposito, para ser lido.
    private let expandedIdleDelay: TimeInterval = 15
    /// Desde quando o ponteiro esta fora, medido pela posicao real dele e nao pelo evento
    /// de saida. `nil` enquanto ele esta em cima.
    private var pointerAwaySince: Date?
    /// Set by the coordinator, which is the only side that knows where the panel is.
    /// Resizing the panel moves the tracking area under the pointer, which can emit an
    /// exit without a matching enter — so the countdown confirms against the pointer's
    /// real position instead of trusting that one event.
    var isPointerOverIsland: (() -> Bool)?

    var metrics: IslandMetrics { isCompact ? .compact(rings: snapshots.count) : fullMetrics }
    /// A geometria do trilho cheio, que e a que dimensiona o painel — ver `IslandCoordinator`.
    var fullMetrics: IslandMetrics { .full(rings: snapshots.count) }
    @Published private(set) var snapshots: [UsageSnapshot] = [UsageSnapshot].preview
    /// O que as sessoes do Claude Code desta maquina estao fazendo agora; nil quando nao ha
    /// nenhuma. Ver `ClaudeSessionMonitor`.
    /// O que as sessoes do Claude Code desta maquina estao fazendo agora, por anel. Ver
    /// `ClaudeSessionMonitor`; cada perfil tem a propria pasta `sessions`.
    @Published private(set) var claudeActivity: [String: SessionActivity] = [:]
    private var sessionMonitors: [String: ClaudeSessionMonitor] = [:]
    private var sessionSubscriptions = Set<AnyCancellable>()
    /// Uma conta por anel do Claude, na ordem em que os aneis aparecem.
    private var claudeProfiles: [ClaudeProfile] = []
    private var refreshTasks: [Task<Void, Never>] = []
    private var claudeWatcher: DispatchSourceFileSystemObject?
    private var lastCodexRead = Date.distantPast
    /// Atualiza a repartição derivada dos registros de cada provedor.
    /// Provedores sem contagem ficam sem a linha de repartição.
    private func atualizarReparticao() {
        let porProvedor = HostSplitReader.read()
        for (i, snapshot) in snapshots.enumerated() {
            snapshots[i].hostSplit = porProvedor[snapshot.source.rawValue]
        }
    }

    private var lastClaudeRead = Date.distantPast
    private let claudeMinInterval: TimeInterval = 900
    /// Duas chamadas ao mesmo tempo levavam dois 429 e dobravam a espera duas vezes.
    private var claudeEmVoo = false
    private var grokEmVoo = false
    private let openCodePercentKey = "usageIsland.manualOpenCodeGoPercent"
    private let openCodeUpdatedAtKey = "usageIsland.manualOpenCodeGoUpdatedAt"

    init() {
        claudeProfiles = ClaudeProfile.discover()
        // Um anel por conta do Claude, e so depois os outros provedores. A ilha inteira e
        // dimensionada por esta contagem, entao ela e decidida uma vez, no arranque: um
        // anel que aparecesse sozinho mudaria a altura do painel debaixo do ponteiro.
        snapshots = claudeProfiles.map { perfil in
            UsageSnapshot(source: .claude, accountSlug: perfil.slug, percentUsed: nil,
                          sessionPercent: nil, resetText: "Lendo uso do Claude",
                          updatedAt: .now, syncState: .loading)
        } + [UsageSnapshot].preview.filter { $0.source != .claude }
        restoreManualPercent(for: .opencode, percentKey: openCodePercentKey, updatedAtKey: openCodeUpdatedAtKey)
    }

    func snapshot(id: String) -> UsageSnapshot {
        snapshots.first(where: { $0.id == id }) ?? snapshots[0]
    }

    /// Sobe a cada vez que a ilha acorda do estado encolhido. E o gatilho da animacao de
    /// carregamento nos aneis — um contador, e nao um booleano, porque hover seguido de hover
    /// precisa animar de novo, e um booleano que ja esta `false` nao avisa ninguem.
    @Published private(set) var wakeCount = 0

    func setHovering(_ hovering: Bool) {
        isHovering = hovering
        if hovering {
            pointerAwaySince = nil
            if isCompact { wakeCount += 1 }
            isCompact = false
            // Olhar para a ilha e o momento em que o numero precisa estar certo.
            refreshNow()
        }
        startIdleWatchdog()
    }

    /// Um relogio de 1 s que confere onde o ponteiro esta de verdade, no lugar de um timer
    /// de uma vez so disparado pelo `mouseExited`.
    ///
    /// O evento de saida se perde, e isso deixava a ilha aberta para sempre: o
    /// `NSTrackingArea` e refeito a cada `updateTrackingAreas`, ou seja, toda vez que o
    /// trilho troca de tamanho (40 -> 92 no hover, e de novo quando o card abre), e o AppKit
    /// nao entrega `mouseExited` de uma area que ele acabou de remover. Se o ponteiro saia
    /// justo nessa janela, ninguem agendava o encolhimento — nao havia timer para o
    /// desempate por posicao salvar. Agora o desempate por posicao e o mecanismo principal
    /// e o evento e so um atalho para acordar rapido.
    private func startIdleWatchdog() {
        guard idleTimer == nil else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickIdleWatchdog() }
        }
    }

    private func stopIdleWatchdog() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func tickIdleWatchdog() {
        guard !isCompact else { stopIdleWatchdog(); return }
        // `isHovering` de proposito nao decide nada aqui: e justamente ele que fica preso em
        // true quando a saida se perde. Com o card aberto o painel e mais largo, entao o
        // ponteiro em cima do card tambem conta como ponteiro na ilha.
        let pointerHere = isPointerOverIsland?() ?? isHovering
        if pointerHere {
            pointerAwaySince = nil
            return
        }
        let away = pointerAwaySince ?? Date()
        pointerAwaySince = away
        guard Date().timeIntervalSince(away) >= (isExpanded ? expandedIdleDelay : idleDelay) else { return }
        if isHovering {
            // O `mouseExited` nunca chegou. Fica no log porque e a unica prova de que o
            // desempate por posicao esta trabalhando.
            IslandLog.write("hover preso: encolhi pela posicao do ponteiro, sem mouseExited")
            isHovering = false
        }
        // O card fecha junto. Antes ele era imune ao ocioso, e como nada fora o clique no
        // mesmo anel o fechava, um clique seguido de mouse para longe deixava a ilha aberta
        // e opaca para sempre — era esse o "nao minimiza mais".
        if isExpanded { dismiss() }
        isCompact = true
        stopIdleWatchdog()
    }

    func select(_ id: String) {
        if selected == id, isExpanded {
            isExpanded = false
            selected = nil
            startIdleWatchdog()
        } else {
            pointerAwaySince = nil
            if isCompact { wakeCount += 1 }
            isCompact = false
            selected = id
            isExpanded = true
            startIdleWatchdog()
        }
    }

    func dismiss() {
        isExpanded = false
        selected = nil
        pointerAwaySince = nil
        startIdleWatchdog()
    }

    func updateOpenCodeGo(percent: Double) {
        saveManualPercent(percent, for: .opencode, percentKey: openCodePercentKey, updatedAtKey: openCodeUpdatedAtKey)
    }

    /// One loop per provider, on purpose. They used to share a single sequential loop, and
    /// that made every ring hostage to the slowest reader: `CodexUsageReader` spawns
    /// `codex app-server` and blocks on `readDataToEndOfFile()`, so a helper that never exits
    /// froze Claude, Grok and OpenCode too — the whole island stopped updating and the only
    /// way out was restarting the app. Separate tasks also let each source pick its own
    /// cadence.
    func startRefreshing() {
        refreshTasks.forEach { $0.cancel() }
        refreshTasks = [
            // Ler o numero do Claude e abrir um arquivo pequeno; o laco aqui e so a rede de
            // seguranca do observador de arquivo abaixo, que e quem da o tempo real.
            loop(every: .seconds(900)) { await $0.refreshClaude() },
            loop(every: .seconds(60)) { await $0.refreshCodex() },
            loop(every: .seconds(60)) { await $0.refreshOpenCode() },
            loop(every: .seconds(60)) { await $0.refreshGrok() },
        ]
        watchClaudeCache()
        observeWake()
        for perfil in claudeProfiles {
            let anel = ClaudeProfile.ringID(slug: perfil.slug)
            let monitor = ClaudeSessionMonitor(directory: perfil.sessionsDirectory)
            monitor.$activity
                .removeDuplicates()
                .sink { [weak self] atividade in self?.claudeActivity[anel] = atividade }
                .store(in: &sessionSubscriptions)
            monitor.start()
            sessionMonitors[anel] = monitor
        }
    }

    /// Tempo real de verdade para o Claude: em vez de perguntar de tempos em tempos, o app
    /// escuta a pasta `~/.claude` e le no instante em que a statusline reescreve o cache.
    ///
    /// **Observa a pasta, nao o arquivo.** A statusline escreve em `.quota-state.tmp` e move
    /// por cima — escrita atomica, de proposito. Um observador presi ao arquivo antigo morre
    /// calado no primeiro `mv`, porque o inode que ele segura deixa de ser o cache.
    private func watchClaudeCache() {
        claudeWatcher?.cancel()
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in await self?.refreshClaude() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        claudeWatcher = source
    }

    /// Depois de a maquina dormir, todo numero na tela e do passado — e os `Task.sleep` dos
    /// lacos so acordam no proprio ritmo. Ler tudo de novo no despertar evita a ilha mostrar,
    /// por ate um minuto, a cota de ontem.
    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshNow() }
            }
    }

    /// Leitura sob demanda. O Codex e o unico caro — ele sobe um processo — entao tem
    /// intervalo minimo proprio para o hover nao virar uma rajada de `codex app-server`.
    func refreshNow() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshClaude()
            await self.refreshOpenCode()
            await self.refreshGrok()
            if Date().timeIntervalSince(lastCodexRead) > 30 { await self.refreshCodex() }
        }
    }

    private func loop(every interval: Duration,
                      _ body: @escaping @MainActor (IslandModel) async -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await body(self)
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func refreshCodex() async {
        lastCodexRead = .now
        guard let reading = await CodexUsageReader.read(),
              let index = snapshots.firstIndex(where: { $0.source == .codex }) else { return }
        snapshots[index].percentUsed = reading.percentUsed
        snapshots[index].resetText = reading.resetText
        snapshots[index].extraWindows = reading.extras.map {
            UsageWindowLine(id: $0.id, title: $0.titulo, percent: $0.percent, reset: $0.reset)
        }
        snapshots[index].updatedAt = reading.updatedAt
        snapshots[index].syncState = .live
        snapshots[index].fidelity = .oficial
    }

    private func refreshOpenCode() async {
        guard let reading = await OpenCodeUsageReader.read(),
              let index = snapshots.firstIndex(where: { $0.source == .opencode }) else { return }
        snapshots[index].percentUsed = reading.percentUsed
        snapshots[index].sessionPercent = reading.rollingPercent
        snapshots[index].extraWindows = reading.extra.map {
            [UsageWindowLine(id: $0.titulo, title: $0.titulo, percent: $0.percent, reset: $0.reset)]
        } ?? []
        snapshots[index].limitLabel = reading.limitLabel
        snapshots[index].limitResetText = reading.limitResetText
        snapshots[index].resetText = reading.resetText
        snapshots[index].updatedAt = reading.updatedAt
        snapshots[index].syncState = .live
        snapshots[index].fidelity = .oficial
    }

    /// The provider's shared weekly allowance includes Build on every machine.
    func refreshGrok() async {
        guard !grokEmVoo else { return }
        grokEmVoo = true
        defer { grokEmVoo = false }
        let reading = await GrokUsageReader.read()
        guard let index = snapshots.firstIndex(where: { $0.source == .grok }) else { return }

        snapshots[index].applyGrokReading(reading)
    }

    /// Batimento a cada 30 min. Ver `IslandLog`.
    ///
    /// Contado em **tempo**, nao em chamadas: o vigia de arquivo em `~/.claude` dispara
    /// dezenas de vezes por segundo quando a pasta esta movimentada, e um contador de
    /// voltas transformava isso em seis linhas de batimento no mesmo segundo.
    private var ultimoBatimento = Date.distantPast

    /// O numero do Claude vem do endpoint da Anthropic, o mesmo que o `/usage` do Claude
    /// Code usa, autenticado com o token do keychain — ver `ClaudeOAuthReader`. O cache da
    /// statusline continua ali atras, so que agora como rede de seguranca: ele congela
    /// quando nao ha sessao viva, e era exatamente essa a falha que este caminho remove.
    private func refreshClaude() async {
        if Date().timeIntervalSince(ultimoBatimento) >= 30 * 60 {
            ultimoBatimento = .now
            IslandLog.write("batimento — " + snapshots.map {
                "\($0.source.rawValue) \($0.percentUsed.map { "\(Int($0.rounded()))%" } ?? "—")"
            }.joined(separator: " · "))
        }
        // A reparticao por maquina vem antes do porteiro de taxa de proposito: ela e um
        // arquivo local escrito por outro processo, nao custa cota, e ficar refem da espera
        // do endpoint deixaria a linha do card velha sem motivo.
        atualizarReparticao()
        guard !claudeEmVoo, Date().timeIntervalSince(lastClaudeRead) >= claudeMinInterval else { return }
        claudeEmVoo = true
        defer { claudeEmVoo = false }
        lastClaudeRead = .now
        for perfil in claudeProfiles {
            let anel = ClaudeProfile.ringID(slug: perfil.slug)
            guard let index = snapshots.firstIndex(where: { $0.id == anel }) else { continue }
            do {
                let leitura = try await ClaudeOAuthReader.read(service: perfil.keychainService)
                aplicar(leitura, em: index)
                claudeFalhaRegistrada[anel] = nil
            } catch {
                aplicarStatusline(em: index, porque: error, anel: anel,
                                  temStatusline: perfil.slug == nil)
            }
        }
    }

    /// Nao repetir a mesma queixa no log a cada volta: uma linha quando o estado muda, por anel.
    private var claudeFalhaRegistrada: [String: String] = [:]

    private func aplicar(_ leitura: ClaudeOAuthReader.Reading, em index: Int) {
        let anterior = snapshots[index].percentUsed
        let manda = leitura.geral
        let percentual = manda?.percent ?? leitura.session?.percent
        if let percentual, anterior == nil || abs(anterior! - percentual) >= 0.5 {
            IslandLog.write("Claude \(anterior.map { "\($0)" } ?? "—") -> \(percentual)"
                            + (manda.map { " (\($0.label))" } ?? ""))
        }
        snapshots[index].percentUsed = percentual
        snapshots[index].limitLabel = manda?.label
        snapshots[index].limitResetText = ClaudeOAuthReader.resetTexto(manda?.resetsAt)
        if let sessao = leitura.session {
            snapshots[index].sessionPercent = sessao.percent
            snapshots[index].sessionLabel = "Sessão atual"
            snapshots[index].resetText = ClaudeOAuthReader.resetTexto(sessao.resetsAt)
        } else {
            snapshots[index].sessionPercent = nil
            snapshots[index].sessionLabel = nil
        }
        // As janelas semanais por modelo aparecem como linhas próprias no cartão.
        snapshots[index].extraWindows = leitura.weeklies
            .filter { $0.kind != manda?.kind }
            .map { UsageWindowLine(id: $0.kind, title: $0.label, percent: $0.percent,
                                   reset: ClaudeOAuthReader.resetTexto($0.resetsAt)) }
        snapshots[index].updatedAt = leitura.updatedAt
        snapshots[index].syncState = .live
        snapshots[index].fidelity = .oficial
    }

    private func aplicarStatusline(em index: Int, porque erro: Error, anel: String, temStatusline: Bool) {
        let motivo: String
        switch erro {
        case ClaudeOAuthReader.ReadFailure.credencial(.ausente): motivo = "sem credencial no keychain"
        case ClaudeOAuthReader.ReadFailure.credencial(.vencido): motivo = "token vencido; o Claude Code renova ao rodar"
        case ClaudeOAuthReader.ReadFailure.credencial(.recusado(let status)): motivo = "keychain recusou (OSStatus \(status))"
        case ClaudeOAuthReader.ReadFailure.limiteDeTaxa(let ate): motivo = "limite de taxa até \(ate)"
        case ClaudeOAuthReader.ReadFailure.http(let status): motivo = "HTTP \(status)"
        default: motivo = "rede indisponível"
        }
        if claudeFalhaRegistrada[anel] != motivo {
            IslandLog.write("\(anel) pelo OAuth falhou (\(motivo))")
            claudeFalhaRegistrada[anel] = motivo
        }
        // Uma leitura oficial ja na tela nao cede lugar para a statusline. As duas contam
        // janelas diferentes, como o teto por modelo e o total semanal, e
        // trocar uma pela outra faz o anel dar um salto que nao aconteceu na vida real.
        // Enquanto a falha for passageira (limite de taxa, rede fora), o certo e manter o
        // numero e dizer que ele envelheceu.
        if snapshots[index].fidelity == .oficial, snapshots[index].percentUsed != nil {
            snapshots[index].limitResetText = "sem atualizar: \(motivo)"
            snapshots[index].syncState = .manual
            return
        }
        // A statusline so existe para a conta padrao: ela escreve num caminho fixo.
        guard temStatusline, let reading = ClaudeUsageReader.read() else {
            // Sem as duas fontes, dizer isso — melhor que deixar o ultimo numero passando
            // por atual.
            snapshots[index].syncState = .manual
            snapshots[index].limitResetText = motivo
            return
        }
        snapshots[index].percentUsed = reading.percentUsed
        snapshots[index].limitLabel = "Todos os modelos"
        snapshots[index].limitResetText = "via statusline — \(motivo)"
        snapshots[index].sessionPercent = nil
        snapshots[index].sessionLabel = nil
        snapshots[index].extraWindows = []
        snapshots[index].updatedAt = reading.updatedAt
        snapshots[index].syncState = .live
        snapshots[index].fidelity = .derivado
    }

    private func restoreManualPercent(for source: UsageSource, percentKey: String, updatedAtKey: String) {
        guard let percent = UserDefaults.standard.object(forKey: percentKey) as? Double,
              (0...100).contains(percent),
              let index = snapshots.firstIndex(where: { $0.source == source }) else { return }
        snapshots[index].percentUsed = percent
        snapshots[index].resetText = "manual"
        snapshots[index].updatedAt = UserDefaults.standard.object(forKey: updatedAtKey) as? Date ?? .now
        snapshots[index].syncState = .manual
        snapshots[index].fidelity = .manual
    }

    private func saveManualPercent(_ percent: Double, for source: UsageSource, percentKey: String, updatedAtKey: String) {
        guard (0...100).contains(percent),
              let index = snapshots.firstIndex(where: { $0.source == source }) else { return }
        snapshots[index].percentUsed = percent
        snapshots[index].resetText = "manual"
        snapshots[index].updatedAt = .now
        snapshots[index].syncState = .manual
        snapshots[index].fidelity = .manual
        UserDefaults.standard.set(percent, forKey: percentKey)
        UserDefaults.standard.set(Date(), forKey: updatedAtKey)
    }
}

extension Array where Element == UsageSnapshot {
    static let preview: [UsageSnapshot] = [
        UsageSnapshot(source: .claude, percentUsed: nil, sessionPercent: nil, resetText: "Aguardando conector Claude", updatedAt: .now, syncState: .unavailable),
        UsageSnapshot(source: .codex, percentUsed: nil, sessionPercent: nil, resetText: "Lendo uso local", updatedAt: .now, syncState: .loading),
        UsageSnapshot(source: .grok, percentUsed: nil, sessionPercent: nil, resetText: "Lendo uso semanal do SuperGrok", updatedAt: .now, syncState: .loading),
        UsageSnapshot(source: .opencode, percentUsed: nil, sessionPercent: nil, resetText: "Lendo plano OpenCode Go", updatedAt: .now, syncState: .loading)
    ]
}
