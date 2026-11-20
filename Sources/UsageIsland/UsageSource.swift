import AppKit
import Combine
import Foundation
import SwiftUI

enum UsageSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case claude = "Claude"
    case codex = "Codex"
    case grok = "SuperGrok"
    case opencode = "OpenCode"
    case openrouter = "OpenRouter"
    case custom = "Personalizado"

    var id: Self { self }

    var tint: Color {
        switch self {
        case .claude: .orange
        case .codex: Color(red: 0.10, green: 0.94, blue: 0.60)
        case .grok: Color(red: 0.45, green: 0.56, blue: 1.00)
        case .opencode: Color(red: 0.97, green: 0.86, blue: 0.10)
        case .openrouter: .purple
        case .custom: .cyan
        }
    }

    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .grok: "bolt.fill"
        case .opencode: "terminal.fill"
        case .openrouter: "arrow.triangle.branch"
        case .custom: "circle.grid.2x2.fill"
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
        guard let percent = UsageValidation.percent(percent) else { return .white.opacity(0.35) }
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
    var failureReason: String? = nil
    var openCodeFailure: OpenCodeUsageReader.Failure? = nil
    var providerBlocked = false
    var entryID: String? = nil
    var customName: String? = nil
    var customSymbol: String? = nil
    var windows: [QuotaWindow] = []
    var primaryWindowID: String? = nil
    var preferredWindowID: String? = nil
    var remaining = false
    var paused = false
    var lowPower = false
    var highContrast = false
    var balanceText: String? = nil
    var lastSuccessfulRead: Date? = nil

    var id: String { entryID ?? accountSlug.map { "\(source.rawValue)-\($0)" } ?? source.rawValue }
    var displayName: String { customName ?? accountSlug.map { "\(source.displayName) (\($0))" } ?? source.displayName }
    var selectedWindow: QuotaWindow? {
        windows.first { $0.id == preferredWindowID } ?? windows.first { $0.id == primaryWindowID } ?? windows.first
    }
    var ringPercent: Double? { selectedWindow?.percent ?? percentUsed }
    var displayPercent: String { UsageValidation.display(remaining ? ringPercent.map { 100 - $0 } : ringPercent, rounded: source == .grok) }
    var quotaSourceNote: String? {
        source == .grok ? "Fonte: API da CLI Grok. O percentual pode diferir da tela do Grok Bot." : nil
    }
    var staleAfter: TimeInterval { source == .claude ? 20 * 60 : 3 * 60 }

    var hasBlockedWindow: Bool {
        providerBlocked || windows.contains { $0.blocked || $0.percent == 100 } || ([percentUsed, sessionPercent] + extraWindows.map { Optional($0.percent) })
            .contains { UsageValidation.percent($0) == 100 }
    }

    func isStale(now: Date = .now) -> Bool {
        guard percentUsed != nil else { return false }
        return syncState == .failed || (syncState == .manual && fidelity != .manual)
            || now.timeIntervalSince(updatedAt) > staleAfter
    }

    func statusText(now: Date = .now) -> String {
        if paused { return "Leitura pausada nas configurações" }
        if syncState == .manual && fidelity == .manual {
            return isStale(now: now) ? "Leitura manual antiga · atualize nas configurações" : "Atualizado manualmente"
        }
        if let failureReason { return syncState == .failed ? "Leitura indisponível · \(failureReason)" : failureReason }
        if isStale(now: now) { return "Leitura antiga · nova tentativa automática" }
        if hasBlockedWindow { return "Limite atingido em alguma janela" }
        return syncState.label
    }

    var lastReadText: String {
        guard lastSuccessfulRead != nil || percentUsed != nil || balanceText != nil else { return "Aguardando primeira leitura" }
        let date = lastSuccessfulRead ?? updatedAt
        return Calendar.current.isDateInToday(date)
            ? "Lido às " + date.formatted(date: .omitted, time: .standard)
            : "Última leitura: " + date.formatted(date: .abbreviated, time: .shortened)
    }

    mutating func markFailed(_ reason: String) {
        syncState = .failed
        failureReason = reason
        if percentUsed == nil { resetText = reason }
    }

    mutating func applyOpenCodeReading(_ reading: OpenCodeUsageReader.Reading?) {
        guard source == .opencode else { return }
        guard let reading else { markFailed("Não foi possível consultar o OpenCode"); return }
        percentUsed = reading.percentUsed
        sessionPercent = reading.rollingPercent
        sessionLabel = "Janela curta"
        extraWindows = reading.extra.map {
            [UsageWindowLine(id: $0.titulo, title: $0.titulo, percent: $0.percent, reset: $0.reset)]
        } ?? []
        limitLabel = reading.limitLabel
        limitResetText = reading.limitResetText
        resetText = reading.resetText
        updatedAt = reading.updatedAt
        lastSuccessfulRead = reading.updatedAt
        syncState = .live
        fidelity = .oficial
        failureReason = nil
        openCodeFailure = nil
        providerBlocked = reading.blocked
        windows = reading.windows
        primaryWindowID = reading.primaryWindowID
    }

    mutating func applyOpenCodeResult(_ result: Result<OpenCodeUsageReader.Reading, OpenCodeUsageReader.Failure>) {
        guard source == .opencode else { return }
        switch result {
        case .success(let reading): applyOpenCodeReading(reading)
        case .failure(let error):
            openCodeFailure = error
            markFailed(error.message)
        }
    }

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
            failureReason = "Não foi possível consultar o SuperGrok"
            windows = []
            return
        }
        percentUsed = weekly.percentUsed
        sessionPercent = reading.web?.percentUsed
        sessionLabel = reading.web?.windowLabel
        limitResetText = weekly.resetText
        resetText = reading.web.map { "\($0.remaining) de \($0.total) restantes" } ?? weekly.resetText
        updatedAt = reading.updatedAt
        lastSuccessfulRead = reading.updatedAt
        syncState = .live
        fidelity = .oficial
        failureReason = reading.webFailure
        windows = [.init(id: "weekly", title: "Pool semanal", percent: weekly.percentUsed,
                         resetsAt: weekly.resetsAt, duration: 7 * 86400)]
        if let web = reading.web { windows.append(.init(id: "web", title: web.windowLabel, percent: web.percentUsed, duration: Double(web.windowSeconds))) }
        primaryWindowID = "weekly"
    }

    /// Quantas barras o card vai desenhar — e o que dita a altura dele.
    var cardRows: Int {
        let quotaRows = windows.isEmpty ? (sessionPercent == nil ? 0 : 1) + (percentUsed == nil ? 0 : 1) + extraWindows.count : windows.count
        return quotaRows + (openCodeFailure?.needsConnection == true ? 2 : 0) + (quotaSourceNote == nil ? 0 : 1)
    }
}

@MainActor
final class IslandModel: ObservableObject {
    @Published var selected: String? = nil
    @Published var isExpanded = false
    /// Idle state: rings only, no numbers, so the island stays out of the way of whatever
    /// is on screen. Hover and detail-card idle times are configured independently.
    @Published private(set) var isCompact = true
    @Published var previewDockSize: DockSizeMode? {
        didSet {
            if previewDockSize != nil { hoverRefreshTask?.cancel() }
        }
    }
    @Published var dockDragging = false
    @Published var dockActivity = DockActivityState()
    private var dockExpiryTask: Task<Void, Never>?
    private var dockExpiryDate: Date?
    var onDockDrag: ((DockDragPhase, NSPoint) -> Void)?
    func sizeMode(compact: Bool) -> DockSizeMode {
        previewDockSize ?? (compact && !settings.value.alwaysShowNumbers ? .compact : .hover)
    }
    var dockSizeMode: DockSizeMode { sizeMode(compact: isCompact) }
    var dockFooterHeight: CGFloat { settings.value.dock.dragHandle ? metrics.dragHandleFooterHeight : 0 }
    var isDockHidden: Bool { previewDockSize == nil && settings.value.dock.autoHide && isCompact && !dockDragging }
    var dockHiddenHeight: CGFloat { min(140, compactMetrics.islandHeight * CGFloat(settings.value.dock.scale)) }
    var dockNoticeVisible: Bool { previewDockSize == nil && settings.value.dock.showCompleted && dockActivity.notice != nil }
    var dockNoticeHeight: CGFloat { 144 }
    var dockDetailVisible: Bool { isExpanded && previewDockSize != .compact }
    var dockHasSidePanel: Bool { dockDetailVisible || dockNoticeVisible }
    var dockZoom: CGFloat {
        if isDockHidden { return 1 }
        return CGFloat(dockSizeMode == .compact ? settings.value.dock.scale : settings.value.dock.hoverScale)
    }
    // The SwiftUI hierarchy lays out in logical points, including the scroll view and its ring
    // positions. Only its outer frame and the native panel hit areas are in display points.
    var dockLogicalRailSize: NSSize {
        if isDockHidden { return NSSize(width: 8, height: dockHiddenHeight) }
        let rail = metrics
        return NSSize(width: rail.railWidth, height: rail.islandHeight + (settings.value.dock.dragHandle ? rail.dragHandleFooterHeight : 0))
    }
    var dockInteractionSize: NSSize {
        let size = dockLogicalRailSize, zoom = dockZoom
        return NSSize(width: size.width * zoom, height: size.height * zoom)
    }
    var dockNeedsAttention: Bool { !dockActivity.waitingEntryIDs.isEmpty }
    private var isHovering = false
    private var idleTimer: Timer?
    private var hoverRefreshTask: Task<Void, Never>?
    /// Desde quando o ponteiro esta fora, medido pela posicao real dele e nao pelo evento
    /// de saida. `nil` enquanto ele esta em cima.
    private var pointerAwaySince: Date?
    /// Set by the coordinator, which is the only side that knows where the panel is.
    /// Resizing the panel moves the tracking area under the pointer, which can emit an
    /// exit without a matching enter — so the countdown confirms against the pointer's
    /// real position instead of trusting that one event.
    var isPointerOverIsland: (() -> Bool)?

    var metrics: IslandMetrics { dockSizeMode == .compact ? compactMetrics : fullMetrics }

    private var availableDockHeight: CGFloat {
        max(1, (IslandScreen.choose(settings.value.screenID)?.visibleFrame.height ?? 900) - 24)
    }

    private var compactMetrics: IslandMetrics {
        var rail = IslandMetrics.compact(rings: snapshots.count)
        let footer = settings.value.dock.dragHandle ? rail.dragHandleFooterHeight : 0
        rail.heightLimit = max(1, availableDockHeight / CGFloat(settings.value.dock.scale) - footer)
        return rail
    }

    var fullMetrics: IslandMetrics {
        let available = availableDockHeight / CGFloat(settings.value.dock.hoverScale)
        let width = CGFloat(settings.value.railWidth)
        var rail = IslandMetrics(railWidth: width, showsPercent: true, ringCount: CGFloat(max(1, snapshots.count)))
        let requiredHeight = rail.islandHeight + (settings.value.dock.dragHandle ? rail.dragHandleFooterHeight : 0)
        if requiredHeight > available {
            let scaledWidth = min(width, max(40, width * available / requiredHeight))
            rail = IslandMetrics(railWidth: scaledWidth, showsPercent: true, ringCount: rail.ringCount)
        }
        rail.heightLimit = max(1, available - (settings.value.dock.dragHandle ? rail.dragHandleFooterHeight : 0))
        return rail
    }

    func dockPanelSize(expanded: Bool) -> NSSize {
        // Reserve both presentations throughout the hover animation. A large resting dock
        // may be wider than a deliberately small hover dock, especially with many icons.
        let compact = compactMetrics, full = fullMetrics
        let restZoom = CGFloat(settings.value.dock.scale), hoverZoom = CGFloat(settings.value.dock.hoverScale)
        func height(_ rail: IslandMetrics) -> CGFloat {
            rail.islandHeight + (settings.value.dock.dragHandle ? rail.dragHandleFooterHeight : 0)
        }
        var width = max(compact.railWidth * restZoom, full.railWidth * hoverZoom)
        var panelHeight = max(height(compact) * restZoom, height(full) * hoverZoom)
        if expanded && previewDockSize != .compact { width = max(width, full.expandedWidth * hoverZoom) }
        if dockNoticeVisible {
            let hiddenWidth = 8 + IslandLayout.bubbleWidth + IslandLayout.bubbleArrowDepth + IslandLayout.bubbleGap
            width = max(width, full.expandedWidth * hoverZoom, compact.expandedWidth * restZoom, hiddenWidth)
            panelHeight = max(panelHeight, dockNoticeHeight * max(1, restZoom, hoverZoom))
        }
        return NSSize(width: width, height: panelHeight)
    }
    @Published var allSnapshots: [UsageSnapshot] = [UsageSnapshot].preview
    /// O que as sessoes do Claude Code desta maquina estao fazendo agora; nil quando nao ha
    /// nenhuma. Ver `ClaudeSessionMonitor`.
    /// O que as sessoes do Claude Code desta maquina estao fazendo agora, por anel. Ver
    /// `ClaudeSessionMonitor`; cada perfil tem a propria pasta `sessions`.
    @Published var claudeActivity: [String: SessionActivity] = [:]
    let ringPositions = RingPositions()
    var sessionMonitors: [String: ClaudeSessionMonitor] = [:]
    var sessionSubscriptions = Set<AnyCancellable>()
    /// Uma conta por anel do Claude, na ordem em que os aneis aparecem.
    var claudeProfiles: [ClaudeProfile] = []
    private var refreshTasks: [Task<Void, Never>] = []
    private var claudeWatcher: DispatchSourceFileSystemObject?
    private var lastCodexRead = Date.distantPast
    private var codexEmVoo = false
    /// Atualiza a repartição derivada dos registros de cada provedor.
    /// Provedores sem contagem ficam sem a linha de repartição.
    private func atualizarReparticao() {
        let porProvedor = HostSplitReader.read()
        for (i, snapshot) in allSnapshots.enumerated() {
            allSnapshots[i].hostSplit = snapshot.accountSlug == nil ? porProvedor[snapshot.source.rawValue] : nil
        }
    }

    private var claudeSchedule = ClaudeRefreshSchedule()
    /// Duas chamadas ao mesmo tempo levavam dois 429 e dobravam a espera duas vezes.
    private var claudeEmVoo = false
    private var ultimoBatimento = Date.distantPast
    private var grokEmVoo = false
    private var openCodeEmVoo = false
    private let openCodePercentKey = "usageIsland.manualOpenCodeGoPercent"
    private let openCodeUpdatedAtKey = "usageIsland.manualOpenCodeGoUpdatedAt"

    let settings: UsageSettings
    let history: UsageHistory
    let services = ServiceStatus()
    let notifications = UsageNotifications()
    let alerts: QuotaAlerts
    @Published var health: [String: ConnectorHealth] = [:]
    @Published var settingsRevision = 0
    var settingsSubscription: AnyCancellable?
    var powerupsTask: Task<Void, Never>?
    var analytics: UsageAnalytics = UsageAnalytics()
    let subscriptions = SubscriptionLedger()
    let localHistory = LocalSessionHistory()
    var activityMonitor: MultiProviderActivity?
    var activitySubscription: AnyCancellable?
    var previousActivity: [String: AgentSession] = [:]
    var activityWarmed = false
    var openRouterInFlight = Set<String>()
    var lastOpenRouterRead: [String: Date] = [:]
    var onSettings: (() -> Void)?
    var onDashboard: (() -> Void)?
    @Published var dashboardTab = 0
    func openSessions() { dashboardTab = 5; onDashboard?() }

    var snapshots: [UsageSnapshot] {
        let temporary = settings.value.dock.showNewActivity ? dockActivity.temporaryEntryIDs(now: .now) : []
        return settings.value.rings.filter { entry in
            entry.visible || (entry.enabled && (temporary.contains(entry.id) || (selected == entry.id && isExpanded)))
        }.compactMap { entry in
            guard var snapshot = allSnapshots.first(where: { $0.id == entry.id }) else { return nil }
            snapshot.remaining = settings.value.showsRemaining(for: entry.id)
            snapshot.lowPower = settings.value.lowPower || ProcessInfo.processInfo.isLowPowerModeEnabled || isCompact
            snapshot.highContrast = settings.value.highContrast
            snapshot.preferredWindowID = entry.preferredWindow
            return snapshot
        }
    }

    init(settings: UsageSettings? = nil, history: UsageHistory? = nil, defaults: UserDefaults = .standard,
         profiles: [ClaudeProfile]? = nil) {
        claudeProfiles = profiles ?? ClaudeProfile.discover()
        self.settings = settings ?? UsageSettings(defaults: defaults, initial: UsageSettings.defaults(profiles: claudeProfiles))
        self.history = history ?? UsageHistory()
        self.alerts = QuotaAlerts(defaults: defaults)
        // Um anel por conta do Claude, e so depois os outros provedores. A ilha inteira e
        // dimensionada por esta contagem, entao ela e decidida uma vez, no arranque: um
        // anel que aparecesse sozinho mudaria a altura do painel debaixo do ponteiro.
        allSnapshots = claudeProfiles.map { perfil in
            UsageSnapshot(source: .claude, accountSlug: perfil.slug, percentUsed: nil,
                          sessionPercent: nil, resetText: "Lendo uso do Claude",
                          updatedAt: .now, syncState: .loading)
        } + [UsageSnapshot].preview.filter { $0.source != .claude }
        restoreManualPercent(for: .opencode, percentKey: openCodePercentKey, updatedAtKey: openCodeUpdatedAtKey)
        reconcileSettings()
        settingsSubscription = self.settings.$value.dropFirst().sink { [weak self] preferences in
            self?.reconcileSettings(preferences)
        }
    }

    func snapshot(id: String) -> UsageSnapshot {
        allSnapshots.first(where: { $0.id == id }) ?? UsageSnapshot(source: .custom, percentUsed: nil,
            sessionPercent: nil, resetText: "Escolha um ícone nas configurações", updatedAt: .now, syncState: .unavailable)
    }

    func setHovering(_ hovering: Bool, now: Date = .now) {
        guard previewDockSize == nil, hovering != isHovering else { return }
        isHovering = hovering
        hoverRefreshTask?.cancel()
        if hovering {
            pointerAwaySince = nil
            if isCompact { isCompact = false }
            // Let the short hover animation finish before Keychain and connector work.
            // Normal polling stays independent and keeps running while the island moves.
            if !refreshTasks.isEmpty {
                let refreshDelay = max(0.35, settings.value.hoverAnimationDuration + 0.07)
                hoverRefreshTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(refreshDelay)) } catch { return }
                    guard let self, self.isHovering, !Task.isCancelled else { return }
                    self.refreshNow()
                }
            }
        } else {
            pointerAwaySince = now
        }
        startIdleWatchdog()
    }

    /// Check the actual pointer too: a missed exit during layout must not leave the
    /// island open. Common mode keeps the short grace period working during tracking.
    private func startIdleWatchdog() {
        guard !isCompact, idleTimer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickIdleWatchdog() }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func stopIdleWatchdog() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    func tickIdleWatchdog(now: Date = .now) {
        guard !dockDragging, previewDockSize == nil else { return }
        guard !isCompact else { stopIdleWatchdog(); return }
        // `isHovering` de proposito nao decide nada aqui: e justamente ele que fica preso em
        // true quando a saida se perde. Com o card aberto o painel e mais largo, entao o
        // ponteiro em cima do card tambem conta como ponteiro na ilha.
        let pointerHere = isPointerOverIsland?() ?? isHovering
        if pointerHere {
            pointerAwaySince = nil
            return
        }
        let away = pointerAwaySince ?? now
        pointerAwaySince = away
        let delay = isExpanded ? settings.value.cardCollapseDelay : settings.value.collapseDelay
        guard now.timeIntervalSince(away) >= delay else { return }
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
            if isCompact { isCompact = false }
            selected = id
            isExpanded = true
            startIdleWatchdog()
        }
        dockActivity.acknowledge(entryID: id)
    }

    func updateDockActivity(now: Date = .now) {
        var updated = dockActivity
        updated.ingest(sessionsByEntryID: claudeActivity.mapValues(\.sessions), rings: settings.value.rings, now: now)
        if updated != dockActivity { dockActivity = updated }
        scheduleDockExpiry()
    }

    private func scheduleDockExpiry() {
        let next = dockActivity.nextExpiration
        guard next != dockExpiryDate else { return }
        dockExpiryTask?.cancel()
        dockExpiryDate = next
        guard let next else { dockExpiryTask = nil; return }
        dockExpiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.01, next.timeIntervalSinceNow))) } catch { return }
            guard let self else { return }
            self.dockActivity.expire(now: .now)
            self.dockExpiryDate = nil
            self.scheduleDockExpiry()
        }
    }

    func dismissDockNotice() { dockActivity.dismissNotice() }

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
            loop(every: .seconds(30)) { await $0.refreshClaude() },
            loop(every: .seconds(30)) { await $0.refreshCodex() },
            loop(every: .seconds(60)) { await $0.refreshOpenCode() },
            loop(every: .seconds(60)) { await $0.refreshGrok() },
        ]
        watchClaudeCache()
        observeWake()
        startPowerups()
        for perfil in claudeProfiles {
            let anel = ClaudeProfile.ringID(slug: perfil.slug)
            let monitor = ClaudeSessionMonitor(directory: perfil.sessionsDirectory)
            monitor.$activity
                .removeDuplicates()
                .sink { [weak self] atividade in self?.receiveClaudeActivity(atividade, entryID: anel) }
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
        Task { @MainActor [weak self] in await self?.refreshOpenRouter() }
        // A slow provider must not delay the Codex refresh triggered by hovering/waking.
        Task { @MainActor [weak self] in await self?.refreshClaude() }
        Task { @MainActor [weak self] in await self?.refreshOpenCode() }
        Task { @MainActor [weak self] in await self?.refreshGrok() }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(lastCodexRead) > 15 { await self.refreshCodex() }
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

    func refreshCodex() async {
        guard !codexEmVoo else { return }
        codexEmVoo = true; defer { codexEmVoo = false }; lastCodexRead = .now
        let entries = settings.value.rings.filter { $0.source == .codex && $0.enabled }
        for entry in entries {
            beginReading(entry.id)
            let reading = await CodexUsageReader.read(directory: entry.directory)
            guard isEnabled(entry.id), let index = allSnapshots.firstIndex(where: { $0.id == entry.id }) else { continue }
            if let reading {
                allSnapshots[index].percentUsed = reading.percentUsed
                allSnapshots[index].limitLabel = reading.limitLabel
                allSnapshots[index].providerBlocked = reading.blocked
                allSnapshots[index].resetText = reading.resetText
                allSnapshots[index].extraWindows = reading.extras.map { UsageWindowLine(id: $0.id, title: $0.titulo, percent: $0.percent, reset: $0.reset) }
                allSnapshots[index].windows = reading.windows
                allSnapshots[index].primaryWindowID = reading.primaryWindowID
                allSnapshots[index].updatedAt = reading.updatedAt
                allSnapshots[index].syncState = .live; allSnapshots[index].fidelity = .oficial
                allSnapshots[index].failureReason = nil
                recordReading(entry.id)
            } else { allSnapshots[index].markFailed("Falha na consulta do Codex · confira o login da CLI") }
            finishReading(entry.id, next: .now.addingTimeInterval(30))
        }
    }

    func refreshOpenCode() async {
        guard isEnabled("OpenCode"), !openCodeEmVoo else { return }
        openCodeEmVoo = true; defer { openCodeEmVoo = false }
        beginReading("OpenCode")
        let reading = await OpenCodeUsageReader.read()
        guard isEnabled("OpenCode"), let index = allSnapshots.firstIndex(where: { $0.id == "OpenCode" }) else { return }
        allSnapshots[index].applyOpenCodeResult(reading)
        finishReading("OpenCode", next: await HTTPBackoff.shared.waiting("OpenCode") ?? .now.addingTimeInterval(60))
        recordReading("OpenCode")
    }

    func refreshGrok() async {
        guard isEnabled("SuperGrok"), !grokEmVoo else { return }
        grokEmVoo = true; defer { grokEmVoo = false }
        beginReading("SuperGrok")
        let reading = await GrokUsageReader.read()
        guard isEnabled("SuperGrok"), let index = allSnapshots.firstIndex(where: { $0.id == "SuperGrok" }) else { return }
        allSnapshots[index].applyGrokReading(reading)
        finishReading("SuperGrok", next: await HTTPBackoff.shared.waiting("SuperGrok") ?? .now.addingTimeInterval(60))
        recordReading("SuperGrok")
    }

    /// quando nao ha sessao viva, e era exatamente essa a falha que este caminho remove.
    func refreshClaude() async {
        if Date().timeIntervalSince(ultimoBatimento) >= 30 * 60 {
            ultimoBatimento = .now
            IslandLog.write("batimento — " + allSnapshots.map {
                "\($0.source.rawValue) \($0.percentUsed.map { "\(Int($0.rounded()))%" } ?? "—")"
            }.joined(separator: " · "))
        }
        // A reparticao por maquina vem antes do porteiro de taxa de proposito: ela e um
        // arquivo local escrito por outro processo, nao custa cota, e ficar refem da espera
        // do endpoint deixaria a linha do card velha sem motivo.
        atualizarReparticao()
        guard !claudeEmVoo else { return }
        claudeEmVoo = true
        defer { claudeEmVoo = false }
        for perfil in claudeProfiles {
            let anel = ClaudeProfile.ringID(slug: perfil.slug)
            guard isEnabled(anel), allSnapshots.contains(where: { $0.id == anel }) else { continue }
            guard let index = allSnapshots.firstIndex(where: { $0.id == anel }) else { continue }
            // Cache-file updates are local and do not spend an API request.
            if perfil.slug == nil, let cached = ClaudeUsageReader.read(),
               allSnapshots[index].percentUsed == nil || cached.updatedAt > allSnapshots[index].updatedAt,
               allSnapshots[index].percentUsed == nil || allSnapshots[index].fidelity == .derivado {
                applyClaudeCache(cached, index: index)
            }
            let service = perfil.keychainService
            let revision = ClaudeOAuthReader.newestItem(service: service)?.modifiedAt
            guard claudeSchedule.reserve(service: service, revision: revision) else { continue }
            beginReading(anel)
            do {
                let leitura = try await ClaudeOAuthReader.read(service: service)
                guard isEnabled(anel), let freshIndex = allSnapshots.firstIndex(where: { $0.id == anel }) else { continue }
                aplicar(leitura, em: freshIndex)
                claudeSchedule.succeeded(service: service)
                claudeFalhaRegistrada[anel] = nil
                finishReading(anel, next: claudeSchedule.nextAttempt(service: service))
                recordReading(anel)
            } catch {
                switch error {
                case ClaudeOAuthReader.ReadFailure.limiteDeTaxa(let until):
                    claudeSchedule.failed(service: service, notBefore: until)
                case ClaudeOAuthReader.ReadFailure.credencial:
                    claudeSchedule.failed(service: service, credentialFailure: true)
                default:
                    claudeSchedule.failed(service: service)
                }
                if let freshIndex = allSnapshots.firstIndex(where: { $0.id == anel }) {
                    aplicarStatusline(em: freshIndex, porque: error, anel: anel, temStatusline: perfil.slug == nil)
                }
                finishReading(anel, next: claudeSchedule.nextAttempt(service: service))
            }
        }
    }

    /// Nao repetir a mesma queixa no log a cada volta: uma linha quando o estado muda, por anel.
    private var claudeFalhaRegistrada: [String: String] = [:]

    private func aplicar(_ leitura: ClaudeOAuthReader.Reading, em index: Int) {
        let anterior = allSnapshots[index].percentUsed
        let manda = leitura.geral
        let percentual = manda?.percent ?? leitura.session?.percent
        if let percentual, anterior == nil || abs(anterior! - percentual) >= 0.5 {
            IslandLog.write("Claude \(anterior.map { "\($0)" } ?? "—") -> \(percentual)"
                            + (manda.map { " (\($0.label))" } ?? ""))
        }
        allSnapshots[index].percentUsed = percentual
        allSnapshots[index].limitLabel = manda?.label
        allSnapshots[index].limitResetText = ClaudeOAuthReader.resetTexto(manda?.resetsAt)
        if let sessao = leitura.session {
            allSnapshots[index].sessionPercent = sessao.percent
            allSnapshots[index].sessionLabel = "Sessão atual"
            allSnapshots[index].resetText = ClaudeOAuthReader.resetTexto(sessao.resetsAt)
        } else {
            allSnapshots[index].sessionPercent = nil
            allSnapshots[index].sessionLabel = nil
        }
        // As janelas semanais por modelo aparecem como linhas próprias no cartão.
        allSnapshots[index].extraWindows = leitura.otherWeeklies
            .map { UsageWindowLine(id: $0.id, title: $0.label, percent: $0.percent,
                                   reset: ClaudeOAuthReader.resetTexto($0.resetsAt)) }
        allSnapshots[index].updatedAt = leitura.updatedAt
        allSnapshots[index].syncState = .live
        allSnapshots[index].fidelity = .oficial
        allSnapshots[index].failureReason = nil
        allSnapshots[index].windows = leitura.windows.map { window in
            QuotaWindow(id: window.id, title: window.label, percent: window.percent, resetsAt: window.resetsAt,
                        duration: window.kind == "session" ? 5 * 3600 : 7 * 86400)
        }
        allSnapshots[index].primaryWindowID = manda?.id ?? leitura.session?.id
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
        if allSnapshots[index].fidelity == .oficial, allSnapshots[index].percentUsed != nil {
            allSnapshots[index].markFailed(motivo)
            return
        }
        // A statusline so existe para a conta padrao: ela escreve num caminho fixo.
        guard temStatusline, let reading = ClaudeUsageReader.read() else {
            // Sem as duas fontes, dizer isso — melhor que deixar o ultimo numero passando
            // por atual.
            allSnapshots[index].markFailed(motivo)
            return
        }
        applyClaudeCache(reading, index: index)
        allSnapshots[index].failureReason = "Consulta oficial: \(motivo)"
    }

    private func applyClaudeCache(_ reading: ClaudeUsageReader.Reading, index: Int) {
        allSnapshots[index].percentUsed = reading.percentUsed
        allSnapshots[index].limitLabel = "Todos os modelos"
        allSnapshots[index].limitResetText = "via cache local"
        allSnapshots[index].sessionPercent = nil
        allSnapshots[index].sessionLabel = nil
        allSnapshots[index].extraWindows = []
        allSnapshots[index].windows = []
        allSnapshots[index].updatedAt = reading.updatedAt
        allSnapshots[index].syncState = .live
        allSnapshots[index].fidelity = .derivado
        allSnapshots[index].failureReason = nil
    }

    private func restoreManualPercent(for source: UsageSource, percentKey: String, updatedAtKey: String) {
        guard let percent = UserDefaults.standard.object(forKey: percentKey) as? Double,
              (0...100).contains(percent),
              let index = allSnapshots.firstIndex(where: { $0.source == source }) else { return }
        allSnapshots[index].percentUsed = percent
        allSnapshots[index].resetText = "manual"
        allSnapshots[index].updatedAt = UserDefaults.standard.object(forKey: updatedAtKey) as? Date ?? .now
        allSnapshots[index].syncState = .manual
        allSnapshots[index].fidelity = .manual
    }

    private func saveManualPercent(_ percent: Double, for source: UsageSource, percentKey: String, updatedAtKey: String) {
        guard (0...100).contains(percent),
              let index = allSnapshots.firstIndex(where: { $0.source == source }) else { return }
        allSnapshots[index].percentUsed = percent
        allSnapshots[index].resetText = "manual"
        allSnapshots[index].updatedAt = .now
        allSnapshots[index].syncState = .manual
        allSnapshots[index].fidelity = .manual
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
