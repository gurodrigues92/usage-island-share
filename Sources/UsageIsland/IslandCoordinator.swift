import AppKit
import Combine
import SwiftUI

@MainActor
final class IslandCoordinator: NSObject {
    private let model = IslandModel()
    private var panel: NSPanel?
    private var statusItem: NSStatusItem?
    private var subscriptions = Set<AnyCancellable>()
    private var pendingShrink: DispatchWorkItem?

    func start() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: model.fullMetrics.railHeightSize),
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
        panel.contentView = NSHostingView(rootView: IslandView(model: model))
        self.panel = panel

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
            .receive(on: RunLoop.main)
            .sink { [weak self] compact in self?.fadePanel(compact: compact) }
            .store(in: &subscriptions)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(repositionAfterScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        model.isPointerOverIsland = { [weak self] in
            guard let panel = self?.panel else { return false }
            return panel.frame.contains(NSEvent.mouseLocation)
        }

        configureStatusItem()
        syncPanel()
        panel.alphaValue = model.isCompact ? Self.compactAlpha : 1
        panel.orderFrontRegardless()
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

    @objc private func repositionAfterScreenChange() {
        syncPanel()
    }

    @objc private func toggleIsland() {
        guard let panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            syncPanel()
            panel.orderFrontRegardless()
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "chart.pie.fill", accessibilityDescription: "Usage Island")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Mostrar/Ocultar Usage Island", action: #selector(toggleIsland), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Atualizar uso do SuperGrok agora", action: #selector(updateSuperGrok), keyEquivalent: ""))
        let webBar = NSMenuItem(title: "Mostrar chat web do Grok no card",
                                action: #selector(toggleGrokWebBar), keyEquivalent: "")
        webBar.state = GrokUsageReader.isWebBarEnabled ? .on : .off
        menu.addItem(webBar)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Encerrar Usage Island", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
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
            O card do Grok ganha uma barra com o limite do chat web (40 consultas por 2 h). \
            Para isso o app precisa da chave de cookie do Arc, e o macOS vai pedir sua senha \
            uma vez — escolha "Permitir Sempre". O anel continua funcionando sem isso.
            """
            alert.addButton(withTitle: "Ativar")
            alert.addButton(withTitle: "Cancelar")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        UserDefaults.standard.set(enabling, forKey: GrokUsageReader.webBarKey)
        sender.state = enabling ? .on : .off
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
    private static let compactAlpha: CGFloat = 0.55

    private func fadePanel(compact: Bool) {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = compact ? Self.compactAlpha : 1
        }
    }

    /// The panel's frame changes in one step, never in step with the view's animation: the
    /// island is pinned to the panel's trailing edge and its centre, so an animated resize
    /// would drag the black rail around. Growth is applied before the view expands; any
    /// shrink waits until the view has finished contracting, over an area that is
    /// transparent by then.
    private func syncPanel(expanded: Bool? = nil) {
        guard let panel else { return }
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
            guard let self, let panel = self.panel else { return }
            panel.setFrame(self.targetFrame(expanded: expandido), display: true)
        }
        pendingShrink = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Always sized for the full rail, even while the island is drawn compact. Resizing the
    /// panel under a running animation showed the previous frame's bitmap centred in the new
    /// bounds for an instant, and the black rail visibly came unstuck from the screen edge.
    /// Only the card, which animates on its own, still moves the panel.
    private func targetFrame(expanded: Bool? = nil) -> NSRect {
        let metrics = model.fullMetrics
        return centred(NSSize(
            width: (expanded ?? model.isExpanded) ? metrics.expandedWidth : metrics.railWidth,
            height: metrics.islandHeight
        ))
    }

    /// Flush with the right edge of the screen, centred vertically.
    private func centred(_ size: NSSize) -> NSRect {
        let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        return NSRect(
            x: visibleFrame.maxX - size.width,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
