import AppKit
import Carbon
import Combine
import SwiftUI

@MainActor
final class IslandCoordinator: NSObject, NSWindowDelegate {
    private let model = IslandModel()
    private var panel: NSPanel?
    private var statusItem: NSStatusItem?
    private var subscriptions = Set<AnyCancellable>()
    private var pendingShrink: DispatchWorkItem?
    private var settingsWindow: NSWindow?
    private var dashboardWindow: NSWindow?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var shortcutEnabled = false
    private var dockDrag: DockDragSession?

    func start() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: model.dockPanelSize(expanded: false)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllApplications, .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let hosting = IslandHostingView(rootView: IslandView(model: model))
        hosting.model = model
        panel.contentView = hosting
        self.panel = panel
        model.onSettings = { [weak self] in self?.showSettings() }
        model.onDashboard = { [weak self] in self?.showDashboard() }
        model.onDockDrag = { [weak self] phase, point in self?.moveDock(phase: phase, point: point) }

        // Sem salto de runloop, e com o valor vindo do proprio publisher.
        //
        // Isto era `.receive(on: RunLoop.main)`, e o motivo era legitimo: `@Published`
        // publica no `willSet`, entao dentro do sink `model.isExpanded` ainda e o valor
        // ANTIGO, e `syncPanel` lia justamente essa propriedade. O preco era um defeito
        // intermitente — `RunLoop.main` agenda no modo default, e enquanto o botao do mouse
        // esta apertado o runloop roda em modo de event tracking. O painel so era
        // redimensionado quando o clique era SOLTO, enquanto a view ja tinha comecado a
        // expandir: o card aparecia cortado dentro de um painel ainda estreito e encaixava
        // de um golpe depois, que e o "o fundo preto se mexe" de quem clica segurando.
        // Recebendo o valor pelo publisher, `syncPanel` nao precisa mais ler o modelo e a
        // troca acontece na mesma volta do evento.
        model.$isExpanded
            .removeDuplicates()
            .sink { [weak self] expandido in self?.syncPanel(expanded: expandido) }
            .store(in: &subscriptions)

        model.$isCompact
            .removeDuplicates()
            .sink { [weak self] compact in self?.fadePanel(compact: compact) }
            .store(in: &subscriptions)
        model.$allSnapshots.map { $0.map(\.id) }.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncPanel() }.store(in: &subscriptions)
        model.$dockActivity.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncPanel() }.store(in: &subscriptions)
        model.$previewDockSize.removeDuplicates().sink { [weak self] _ in
            self?.syncDockAfterPreferenceChange()
        }.store(in: &subscriptions)
        model.$selected.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncPanel() }.store(in: &subscriptions)
        model.settings.$value.sink { [weak self] _ in
            self?.syncDockAfterPreferenceChange(updateSettings: true)
        }.store(in: &subscriptions)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(repositionAfterScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(applicationVisibilityChanged), name: name, object: nil)
        }

        model.isPointerOverIsland = { [weak self] in
            guard let panel = self?.panel else { return false }
            guard let self else { return false }
            guard panel.isVisible else { return false }
            if self.model.dockDragging { return true }
            if self.model.dockDetailVisible { return panel.frame.contains(NSEvent.mouseLocation) }
            let pointer = NSEvent.mouseLocation
            let rail = IslandPlacement.interactionFrame(in: panel.frame, size: self.model.dockInteractionSize,
                edge: self.model.settings.value.edge)
            if rail.contains(pointer) { return true }
            return self.model.dockNoticeVisible && IslandPlacement.noticeFrame(in: panel.frame,
                railWidth: self.model.dockInteractionSize.width, height: self.model.dockNoticeHeight,
                edge: self.model.settings.value.edge, zoom: self.model.dockZoom).contains(pointer)
        }

        configureStatusItem()
        configureMainMenu()
        configureShortcut()
        syncPanel()
        panel.alphaValue = model.dockSizeMode == .compact ? model.settings.value.compactOpacity : 1
        updateDockVisibility()
        model.startRefreshing()

        // Screenshot aid: ISLAND_PREVIEW=Claude opens that card immediately.
        // ISLAND_PREVIEW_APOS=2 atrasa a abertura, que e o unico jeito de filmar a
        // transicao de fechado para aberto: sem espera ela acontece antes de qualquer
        // observador conseguir amostrar.
        if let name = ProcessInfo.processInfo.environment["ISLAND_PREVIEW"] {
            let espera = ProcessInfo.processInfo.environment["ISLAND_PREVIEW_APOS"]
                .flatMap(Double.init) ?? 0
            if espera > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + espera) { [model] in
                    model.select(name)
                }
            } else {
                model.select(name)
            }
        }
    }

    // @Published emits before the assignment. Read the committed sizes on the
    // next turn, including the event-tracking mode used by an active slider.
    private func syncDockAfterPreferenceChange(updateSettings: Bool = false) {
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.syncPanel()
                self.fadePanel(compact: self.model.isCompact)
                if updateSettings {
                    self.configureShortcut()
                    self.settingsWindow?.appearance = self.model.settings.value.theme.appearance
                    self.dashboardWindow?.appearance = self.model.settings.value.theme.appearance
                    self.updateDockVisibility()
                }
            }
        }
    }

    @objc private func repositionAfterScreenChange() {
        if dockDrag != nil { moveDock(phase: .cancel, point: .zero) }
        syncPanel()
    }

    @objc private func toggleIsland() {
        model.settings.edit { $0.dock.enabled.toggle() }
        updateDockVisibility()
    }

    @objc private func applicationVisibilityChanged() { updateDockVisibility() }

    private func updateDockVisibility(excluding closedWindow: NSWindow? = nil) {
        guard let panel else { return }
        let hasAppWindow = [settingsWindow, dashboardWindow].compactMap { $0 }.contains {
            $0 !== closedWindow && $0.isVisible && !$0.isMiniaturized
        }
        let allowed = model.settings.value.dock.enabled &&
            (model.settings.value.dock.presentation == .overlay || (NSApp.isActive && hasAppWindow))
        if allowed { panel.orderFrontRegardless() }
        else {
            if dockDrag != nil { moveDock(phase: .cancel, point: .zero) }
            panel.orderOut(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow { model.previewDockSize = nil }
        updateDockVisibility(excluding: notification.object as? NSWindow)
    }
    func windowDidMiniaturize(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow { model.previewDockSize = nil }
        updateDockVisibility()
    }
    func windowDidDeminiaturize(_ notification: Notification) { updateDockVisibility() }
    func windowDidBecomeKey(_ notification: Notification) { updateDockVisibility() }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarIcon.make()
        item.button?.toolTip = "Usage Island · uso das IAs"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Configurações…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Histórico e projetos…", action: #selector(showDashboard), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "Atualizar todas as IAs", action: #selector(updateAll), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Mostrar/Ocultar Usage Island", action: #selector(toggleIsland), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Atualizar uso do SuperGrok agora", action: #selector(updateSuperGrok), keyEquivalent: ""))
        let webBar = NSMenuItem(title: "Mostrar chat web do Grok no card",
                                action: #selector(toggleGrokWebBar), keyEquivalent: "")
        webBar.state = GrokUsageReader.isWebBarEnabled ? .on : .off
        menu.addItem(webBar)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Encerrar Usage Island", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for row in menu.items where row.action != #selector(NSApplication.terminate(_:)) { row.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func updateAll() { model.refreshNow() }
    @objc private func showSettings() {
        if settingsWindow == nil { settingsWindow = window(title: "Usage Island — Configurações", content: SettingsView(model: model), autosave: "UsageIslandSettings", size: NSSize(width: 820, height: 700)) }
        if let settingsWindow { IslandWindowPresentation.show(settingsWindow) }
        updateDockVisibility()
    }
    @objc private func showDashboard() {
        if dashboardWindow == nil { dashboardWindow = window(title: "Usage Island — Histórico e projetos", content: DashboardView(model: model), autosave: "UsageIslandDashboard", size: NSSize(width: 900, height: 730)) }
        if let dashboardWindow { IslandWindowPresentation.show(dashboardWindow) }
        updateDockVisibility()
    }
    private func window<Content: View>(title: String, content: Content, autosave: String, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.appearance = model.settings.value.theme.appearance
        window.contentView = NSHostingView(rootView: content)
        window.minSize = NSSize(width: 780, height: 650)
        window.center(); window.setFrameAutosaveName(autosave)
        return window
    }
    private func configureMainMenu() {
        let menu = NSMenu(); let app = NSMenu(); let item = NSMenuItem(); item.submenu = app; menu.addItem(item)
        let settings = NSMenuItem(title: "Configurações…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self; app.addItem(settings)
        let dashboard = NSMenuItem(title: "Histórico e projetos…", action: #selector(showDashboard), keyEquivalent: "h"); dashboard.target = self; app.addItem(dashboard)
        app.addItem(.separator()); app.addItem(NSMenuItem(title: "Encerrar Usage Island", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        NSApp.mainMenu = menu
    }
    private func configureShortcut() {
        let enabled = model.settings.value.shortcutEnabled
        guard enabled != shortcutEnabled else { return }
        shortcutEnabled = enabled
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        guard enabled else { return }
        if hotKeyHandler == nil {
            var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                let coordinator = Unmanaged<IslandCoordinator>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { coordinator.toggleIsland() }
                return noErr
            }, 1, &specification, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        }
        let identifier = EventHotKeyID(signature: 0x5549534C, id: 1)
        if RegisterEventHotKey(UInt32(kVK_ANSI_U), UInt32(controlKey | optionKey), identifier, GetApplicationEventTarget(), 0, &hotKey) != noErr {
            shortcutEnabled = false; model.settings.edit { $0.shortcutEnabled = false }
        }
    }

    /// Off by default: it is the only reading that needs Arc's cookie, and getting that cookie
    /// means a login-keychain dialog. Left on, the same call also killed the app under launchd,
    /// so the login agent never stayed up. The ring does not depend on it.
    @objc private func toggleGrokWebBar(_ sender: NSMenuItem) {
        let enabling = !GrokUsageReader.isWebBarEnabled
        if enabling {
            let alert = NSAlert()
            alert.messageText = "Ler a sessão do Grok no Arc?"
            alert.informativeText = """
            O card do Grok ganha uma barra com o limite atual do chat web. \
            Para isso o app precisa da chave de cookie do Arc, e o macOS vai pedir sua senha \
            uma vez — escolha "Permitir Sempre". O anel continua funcionando sem isso.
            """
            alert.addButton(withTitle: "Ativar")
            alert.addButton(withTitle: "Cancelar")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        GrokUsageReader.setWebBarEnabled(enabling)
        sender.state = enabling ? .on : .off
        Task { await model.refreshGrok() }
    }

    @objc private func updateSuperGrok() {
        Task { await model.refreshGrok() }
    }

    @objc private func updateOpenCodeGo() {
        presentManualUsageAlert(
            title: "Uso semanal do OpenCode Go",
            message: "Informe a porcentagem semanal mostrada no console do OpenCode Go.",
            save: model.updateOpenCodeGo(percent:)
        )
    }

    private func presentManualUsageAlert(title: String, message: String, save: (Double) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Salvar")
        alert.addButton(withTitle: "Cancelar")

        let field = NSTextField(string: "")
        field.placeholderString = "0–100"
        field.alignment = .center
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn,
              let percent = Double(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              (0...100).contains(percent) else { return }
        save(percent)
    }

    /// Encolhida, a ilha fica translucida; com o ponteiro em cima, opaca. O objetivo e ela
    /// nao disputar atencao com a janela que esta atras dela na borda da tela.
    ///
    /// A opacidade e do painel inteiro, e nao do fundo da `RailShape`, por dois motivos: a
    /// transicao sai de graca e num passo so (o AppKit anima `alphaValue`), e ela vale para
    /// tudo — aneis, marcas e numeros — em vez de deixar o desenho opaco boiando sobre um
    /// preto transparente. O valor nao chega a zero de proposito: ilha invisivel e ilha que o
    /// usuario nao acha para trazer de volta.
    private func fadePanel(compact: Bool) {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = model.settings.value.hoverAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = model.sizeMode(compact: compact) == .compact && !model.dockDragging ? model.settings.value.compactOpacity : 1
        }
    }

    /// The panel's frame changes in one step, never in step with the view's animation: the
    /// island is pinned to the panel's trailing edge and its centre, so an animated resize
    /// would drag the black rail around. Growth is applied before the view expands; any
    /// shrink waits until the view has finished contracting, over an area that is
    /// transparent by then.
    private func syncPanel(expanded: Bool? = nil) {
        guard let panel, dockDrag == nil else { return }
        let expandido = expanded ?? model.isExpanded
        let target = targetFrame(expanded: expandido)
        let current = panel.frame
        let grown = NSSize(
            width: max(target.width, current.width),
            height: max(target.height, current.height)
        )
        pendingShrink?.cancel()
        // Compared as a whole frame, not just a size: the first call and a screen change
        // both leave the size untouched and only the origin wrong.
        let grownFrame = centred(grown)
        if grownFrame != current {
            panel.setFrame(grownFrame, display: true)
        }
        guard grown != target.size else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel, self.dockDrag == nil else { return }
            panel.setFrame(self.targetFrame(expanded: expandido), display: true)
        }
        pendingShrink = work
        DispatchQueue.main.asyncAfter(deadline: .now() + model.settings.value.panelShrinkDelay, execute: work)
    }

    /// Always sized for the full rail, even while the island is drawn compact. Resizing the
    /// panel under a running animation showed the previous frame's bitmap centred in the new
    /// bounds for an instant, and the black rail visibly came unstuck from the screen edge.
    /// Only the card, which animates on its own, still moves the panel.
    private func targetFrame(expanded: Bool? = nil) -> NSRect {
        centred(model.dockPanelSize(expanded: expanded ?? model.isExpanded))
    }

    private func moveDock(phase: DockDragPhase, point: NSPoint) {
        guard let panel else { return }
        switch phase {
        case .begin:
            guard dockDrag == nil, point.x.isFinite, point.y.isFinite,
                  let screen = panel.screen ?? IslandScreen.choose(model.settings.value.screenID) else { return }
            pendingShrink?.cancel()
            dockDrag = DockDragSession(startPoint: point, initialFrame: panel.frame, visibleFrame: screen.visibleFrame)
            model.dockDragging = true
            panel.alphaValue = 1
        case .change:
            guard let drag = dockDrag else { return }
            panel.setFrameOrigin(drag.frame(at: point).origin)
        case .end:
            guard let drag = dockDrag else { return }
            let final = drag.frame(at: point)
            panel.setFrameOrigin(final.origin)
            // Persist once, after tracking finishes. Intermediate mouse events only move the panel.
            let position = IslandPlacement.position(for: final, visible: drag.visibleFrame)
            model.settings.edit { $0.verticalPosition = position }
            dockDrag = nil
            model.dockDragging = false
            syncPanel()
            fadePanel(compact: model.isCompact)
        case .cancel:
            guard let drag = dockDrag else { return }
            panel.setFrameOrigin(drag.initialFrame.origin)
            dockDrag = nil
            model.dockDragging = false
            syncPanel()
            fadePanel(compact: model.isCompact)
        }
    }

    /// Flush with the right edge of the screen, centred vertically.
    private func centred(_ size: NSSize) -> NSRect {
        let visible = IslandScreen.choose(model.settings.value.screenID)?.visibleFrame ?? .zero
        return IslandPlacement.frame(size: size, visible: visible, edge: model.settings.value.edge,
                                     position: model.settings.value.verticalPosition)
    }
}

enum IslandPlacement {
    static func frame(size: NSSize, visible: NSRect, edge: IslandEdge, position: Double) -> NSRect {
        let height = min(size.height, max(1, visible.height - 24))
        let width = min(size.width, visible.width)
        let fraction = position.isFinite ? min(1, max(0, position)) : 0.5
        return NSRect(x: edge == .left ? visible.minX : visible.maxX - width,
                      y: visible.minY + (visible.height - height) * (1 - fraction), width: width, height: height)
    }

    /// Inverse of frame(...). The preference counts from the top while AppKit y grows upward.
    static func position(for frame: NSRect, visible: NSRect) -> Double {
        let travel = visible.height - frame.height
        guard travel.isFinite, travel > 0, frame.minY.isFinite, visible.minY.isFinite else { return 0.5 }
        return min(1, max(0, Double(1 - (frame.minY - visible.minY) / travel)))
    }

    static func verticallyMoved(_ frame: NSRect, delta: CGFloat, visible: NSRect) -> NSRect {
        guard delta.isFinite, visible.minY.isFinite, visible.maxY.isFinite else { return frame }
        let maximum = max(visible.minY, visible.maxY - frame.height)
        return NSRect(x: frame.minX, y: min(maximum, max(visible.minY, frame.minY + delta)),
                      width: frame.width, height: frame.height)
    }

    /// Shared by native hit testing and the idle watchdog, including the handle and hidden edge strip.
    static func interactionFrame(in bounds: NSRect, size: NSSize, edge: IslandEdge) -> NSRect {
        let width = min(bounds.width, max(0, size.width))
        let height = min(bounds.height, max(0, size.height))
        return NSRect(x: edge == .left ? bounds.minX : bounds.maxX - width,
                      y: bounds.midY - height / 2, width: width, height: height)
    }

    static func noticeFrame(in bounds: NSRect, railWidth: CGFloat, height: CGFloat, edge: IslandEdge, zoom: CGFloat = 1) -> NSRect {
        let width = (IslandLayout.bubbleWidth + IslandLayout.bubbleArrowDepth) * zoom
        let height = height * zoom
        let gap = IslandLayout.bubbleGap * zoom
        let x = edge == .left ? bounds.minX + railWidth + gap : bounds.maxX - railWidth - gap - width
        return NSRect(x: x, y: bounds.midY - height / 2, width: width, height: height).intersection(bounds)
    }
}

struct DockDragSession {
    let startPoint: NSPoint
    let initialFrame: NSRect
    let visibleFrame: NSRect

    func frame(at point: NSPoint) -> NSRect {
        IslandPlacement.verticallyMoved(initialFrame, delta: point.y - startPoint.y, visible: visibleFrame)
    }
}

@MainActor
final class IslandHostingView: NSHostingView<IslandView> {
    weak var model: IslandModel?
    // Plain SwiftUI buttons otherwise consume the first click to activate a window.
    // This panel deliberately never activates, so its controls must accept that click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let model, !model.dockDetailVisible else { return super.hitTest(point) }
        let rail = IslandPlacement.interactionFrame(in: bounds, size: model.dockInteractionSize, edge: model.settings.value.edge)
        let notice = model.dockNoticeVisible && IslandPlacement.noticeFrame(in: bounds,
            railWidth: model.dockInteractionSize.width, height: model.dockNoticeHeight,
            edge: model.settings.value.edge, zoom: model.dockZoom).contains(point)
        return rail.contains(point) || notice ? super.hitTest(point) : nil
    }
}

@MainActor
enum IslandWindowPresentation {
    static func show(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !hasVisibleTitlebar(window.frame, screens: NSScreen.screens.map(\.visibleFrame)),
           let screen = NSScreen.main ?? NSScreen.screens.first {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - window.frame.width / 2,
                                          y: screen.visibleFrame.midY - window.frame.height / 2))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    static func hasVisibleTitlebar(_ frame: NSRect, screens: [NSRect]) -> Bool {
        let titlebar = NSRect(x: frame.minX, y: frame.maxY - 28, width: frame.width, height: 28)
        return screens.contains {
            let overlap = $0.intersection(titlebar)
            return !overlap.isNull && overlap.width >= min(120, frame.width) && overlap.height >= 20
        }
    }
}
