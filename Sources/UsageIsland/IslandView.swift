import AppKit
import SwiftUI

/// Geometry derived from the reference mock. Every value is a measured ratio of
/// `railWidth`, so the whole island rescales from that one number — which is what lets
/// the same rail exist in two sizes.
struct IslandMetrics: Equatable {
    let railWidth: CGFloat
    let showsPercent: Bool
    /// Quantos aneis o trilho desenha. Deixou de ser fixo quando o Claude passou a poder
    /// ter mais de uma conta: a altura da ilha sai daqui.
    let ringCount: CGFloat

    /// Hovered: the reference layout, numbers included.
    static func full(rings: Int) -> IslandMetrics {
        IslandMetrics(railWidth: 92, showsPercent: true, ringCount: CGFloat(max(1, rings)))
    }
    /// Idle: rings and their arcs only. Roughly a sixth of the full island's area, so it
    /// reads as a docked sliver rather than a panel sitting on top of other windows.
    /// 40 is the floor measured on this screen: the ring lands at 23pt with a 3pt stroke,
    /// which is the thinnest arc that still shows how much of the circle is filled.
    static func compact(rings: Int) -> IslandMetrics {
        IslandMetrics(railWidth: 40, showsPercent: false, ringCount: CGFloat(max(1, rings)))
    }

    /// Each end sweeps back into the screen edge over 0.946x the rail's width, as two
    /// tangent arcs: a wide concave sweep off the edge closing into a tighter convex
    /// corner. Their sweep angle and combined radius follow from the flare's width and
    /// height; `flareRadiusSplit` is the only free parameter — 0.567 fits the reference
    /// to 4.9px rms on its 186px-wide rail.
    var flareHeight: CGFloat { railWidth * 0.946 }

    var ringDiameter: CGFloat { (railWidth * 0.57).rounded() }
    var ringStroke: CGFloat { max(3, (railWidth * 0.043).rounded()) }
    /// The mark reads larger than the reference's 0.32: at this rail width its logos were
    /// too small to recognise, and the percentage carries less weight than the provider.
    var markSize: CGFloat { (ringDiameter * 0.46).rounded() }
    var ringTextGap: CGFloat { showsPercent ? 8 : 0 }
    var percentFontSize: CGFloat { 15 }
    /// Zero when the numbers are hidden, so the block collapses onto the ring instead of
    /// leaving a gap where the text used to be.
    var percentLineHeight: CGFloat { showsPercent ? 18 : 0 }
    var ringBlockHeight: CGFloat { ringDiameter + ringTextGap + percentLineHeight }
    /// The mock's pitch (1.48x the width) is generous for its three rings; with four
    /// the island would fill half the screen, so the gap is tightened here.
    var ringSpacing: CGFloat { (railWidth * 0.24).rounded() }
    var ringPitch: CGFloat { ringBlockHeight + ringSpacing }
    /// Top of the rail to the top of the first ring. Slightly less than the flare, so
    /// the first ring sits into the curve exactly as it does in the reference.
    var contentInset: CGFloat { (railWidth * 0.74).rounded() }

    var islandHeight: CGFloat {
        contentInset * 2 + ringBlockHeight + ringPitch * (ringCount - 1)
    }
    var firstRingCenterY: CGFloat { contentInset + ringDiameter / 2 }
    func ringCenterY(_ index: Int) -> CGFloat { firstRingCenterY + ringPitch * CGFloat(index) }

    var railHeightSize: NSSize { NSSize(width: railWidth, height: islandHeight) }

    var expandedWidth: CGFloat {
        railWidth + IslandLayout.bubbleGap + IslandLayout.bubbleArrowDepth + IslandLayout.bubbleWidth
    }
}

/// Values that do not follow the rail's size: the detail card is the same either way.
enum IslandLayout {
    static let flareRadiusSplit: CGFloat = 0.567
    static let bubbleWidth: CGFloat = 300
    static let bubbleCorner: CGFloat = 20
    static let bubblePadding: CGFloat = 16
    static let bubbleArrowDepth: CGFloat = 32
    static let bubbleArrowBase: CGFloat = 44
    static let bubbleGap: CGFloat = 18
    /// Uma barra ocupa 47pt mais os 12pt de respiro; o resto e o cabecalho, a linha de
    /// procedencia e o preenchimento. O card cresce com o numero de janelas porque o Claude
    /// passou a ter mais de duas — sessao, total semanal e um teto por modelo.
    /// O card nao lista mais as sessoes: quem esta trabalhando ja aparece no anel, e a
    /// lista empurrava o resto do card para baixo sem dizer nada que o anel nao dissesse.
    static func bubbleHeight(rows: Int, splitLine: Bool = false) -> CGFloat {
        84 + 59 * CGFloat(max(1, rows)) + (splitLine ? 34 : 0)
    }
}

struct IslandView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let metrics = model.metrics
        HStack(spacing: 0) {
            if let anel = model.selected, model.isExpanded,
               let index = model.snapshots.firstIndex(where: { $0.id == anel }) {
                let snapshot = model.snapshots[index]
                let height = IslandLayout.bubbleHeight(
                    rows: snapshot.cardRows,
                    splitLine: snapshot.hostSplit != nil)
                let (offset, arrowY) = bubblePlacement(ring: index, height: height, metrics: metrics)
                ZStack {
                    DetailBubble(snapshot: snapshot, arrowY: arrowY)
                        .frame(width: IslandLayout.bubbleWidth + IslandLayout.bubbleArrowDepth, height: height)
                        .offset(y: offset)
                }
                .frame(width: metrics.expandedWidth - metrics.railWidth, height: metrics.islandHeight, alignment: .leading)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .trailing)).combined(with: .offset(x: 16)),
                    removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .trailing))
                ))
            }
            Rail(model: model, metrics: metrics)
                .frame(width: metrics.railWidth, height: metrics.islandHeight)
        }
        .frame(width: model.isExpanded ? metrics.expandedWidth : metrics.railWidth, height: metrics.islandHeight, alignment: .trailing)
        .background(HoverReporter { model.setHovering($0) })
        // Pinned to the panel's trailing edge: the panel is resized in one step while this
        // frame animates, and centring it would drag the black rail along with the card.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .animation(.spring(response: 0.42, dampingFraction: 0.91, blendDuration: 0.12), value: model.isExpanded)
        .animation(.spring(response: 0.36, dampingFraction: 0.88), value: model.selected)
        .animation(.spring(response: 0.44, dampingFraction: 0.90), value: model.isCompact)
    }

    /// Bubble vertical offset (from the island centre) and the arrow's y inside the
    /// bubble, so the arrow tip always points at the selected ring's centre even when
    /// the bubble is clamped to stay inside the island.
    private func bubblePlacement(ring index: Int, height: CGFloat, metrics: IslandMetrics) -> (CGFloat, CGFloat) {
        let ringY = metrics.ringCenterY(index)
        let half = height / 2
        let centerY = min(max(ringY, half), metrics.islandHeight - half)
        return (centerY - metrics.islandHeight / 2, ringY - (centerY - half))
    }
}

/// SwiftUI's `onHover` only fires while the app is active; this one is an accessory app
/// whose panel never takes focus, so the tracking area is installed by hand with
/// `.activeAlways`. It never takes part in hit testing, so clicks still reach the rings.
private struct HoverReporter: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) { view.onChange = onChange }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct Rail: View {
    @ObservedObject var model: IslandModel
    let metrics: IslandMetrics

    var body: some View {
        ZStack(alignment: .top) {
            RailShape().fill(Color.black)
            VStack(spacing: metrics.ringSpacing) {
                ForEach(Array(model.snapshots.enumerated()), id: \.element.id) { posicao, snapshot in
                    UsageRing(
                        snapshot: snapshot,
                        // So o Claude tem registro de sessao para ler; ver `ClaudeSessionMonitor`.
                        activity: model.claudeActivity[snapshot.id],
                        metrics: metrics,
                        posicao: posicao,
                        isSelected: model.selected == snapshot.id && model.isExpanded,
                        isCompact: model.isCompact,
                        wakeCount: model.wakeCount,
                        action: { model.select(snapshot.id) }
                    )
                }
            }
            .padding(.top, metrics.contentInset)
        }
    }
}

private struct UsageRing: View {
    let snapshot: UsageSnapshot
    let activity: SessionActivity?
    let metrics: IslandMetrics
    /// Posicao no trilho, so para escalonar a animacao de entrada.
    let posicao: Int
    let isSelected: Bool
    /// Encolhida, a ilha e preto e branco: os aneis viram cinza e so voltam a cor quando o
    /// ponteiro chega. A cor semantica (verde/amarelo/vermelho) e um alerta, e alerta que
    /// fica aceso o tempo todo na borda da tela deixa de ser alerta.
    let isCompact: Bool
    /// Muda a cada despertar; ver `IslandModel.wakeCount`.
    let wakeCount: Int
    let action: () -> Void
    @State private var isHovered = false
    @State private var didAppear = false
    /// Multiplicador do arco durante a animacao de carregamento: vai a 0 no instante do
    /// despertar e volta a 1 animado, o que faz o anel se redesenhar do zero ate o valor real.
    @State private var sweep: Double = 1
    /// Graus acumulados de giro. Acumular em vez de zerar e o que permite duas voltas
    /// completas sem o anel "voltar" no fim da animacao.
    @State private var spin: Double = 0

    /// Quase branco, e nao um cinza medio: encolhida a ilha esta a 55% de opacidade, entao
    /// tudo clareia na direcao do que estiver atras dela. Com cinza 0,62 o arco e o trilho
    /// #2E2E2E chegavam na mesma tinta sobre fundo claro e o anel deixava de dizer quanto
    /// foi usado — preto e branco nao pode custar a informacao.
    private var ringColor: Color {
        isCompact ? Color(white: 0.95) : Color.usageLevel(snapshot.percentUsed)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: metrics.ringTextGap) {
                ZStack {
                    Circle().stroke(Color.islandTrack, lineWidth: metrics.ringStroke)
                    Circle()
                        .trim(from: 0, to: didAppear ? max(0.015, (snapshot.percentUsed ?? 0) / 100) * sweep : 0)
                        .stroke(ringColor, style: StrokeStyle(lineWidth: metrics.ringStroke, lineCap: .round))
                        // O giro entra por ultimo, depois do trim: girar o `Circle` antes de
                        // recorta-lo giraria o recorte junto e o arco ficaria parado.
                        .rotationEffect(.degrees(-90 + spin))
                    if let activity {
                        ActivityIndicator(state: activity.state, metrics: metrics)
                    }
                    ProviderMark(source: snapshot.source)
                        .frame(width: metrics.markSize, height: metrics.markSize)
                        .foregroundStyle(.white)
                }
                .frame(width: metrics.ringDiameter, height: metrics.ringDiameter)
                .scaleEffect(isSelected ? 1.06 : (isHovered ? 1.04 : 1))
                // Kept in the tree and given zero height when idle, so it fades out with the
                // rest of the shrink instead of popping in and out of the layout.
                Text(snapshot.displayPercent)
                    .font(.system(size: metrics.percentFontSize, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(height: metrics.percentLineHeight)
                    .opacity(metrics.showsPercent ? 1 : 0)
                    .clipped()
            }
            .frame(width: metrics.railWidth, height: metrics.ringBlockHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(IslandPressStyle())
        .help(activity.map { "\(snapshot.syncState.label) · \($0.resumo)" } ?? snapshot.syncState.label)
        .onHover { hovering in withAnimation(.spring(response: 0.25, dampingFraction: 0.66)) { isHovered = hovering } }
        .onAppear { withAnimation(.easeOut(duration: 0.82).delay(animationDelay)) { didAppear = true } }
        // Duas voltas completas enquanto a ilha cresce e a cor volta: o anel se redesenha do
        // zero, como se estivesse buscando o numero — que e o que de fato acontece, porque o
        // hover tambem dispara uma leitura nova.
        .onChange(of: wakeCount) { _, _ in
            sweep = 0
            withAnimation(.easeInOut(duration: 0.9)) {
                sweep = 1
                spin += 720
            }
        }
        .animation(.easeInOut(duration: isCompact ? 0.45 : 0.9), value: isCompact)
        .accessibilityLabel("\(snapshot.displayName), \(snapshot.displayPercent) usado")
    }

    private var animationDelay: Double {
        0.05 + 0.05 * Double(posicao)
    }
}

/// O anel diz o que as sessoes estao fazendo sem que ninguem precise abrir nada: um arco
/// fino girando por dentro enquanto alguma trabalha, um anel ambar pulsando quando alguma
/// esta parada esperando voce.
///
/// Ele vive por dentro do anel de cota, e nao ao lado: a ilha tem 40pt de largura quando
/// encolhida e nao cabe um segundo indicador; alem disso a leitura certa e "esta sessao,
/// deste provedor", que so a sobreposicao entrega.
private struct ActivityIndicator: View {
    let state: SessionActivity.State
    let metrics: IslandMetrics
    @State private var girando = false
    @State private var pulsando = false

    private var espessura: CGFloat { max(1.5, metrics.ringStroke * 0.55) }

    var body: some View {
        Group {
            switch state {
            case .working:
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: espessura, lineCap: .round))
                    .rotationEffect(.degrees(girando ? 360 : 0))
                    .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: girando)
                    .onAppear { girando = true }
            case .waiting:
                Circle()
                    .stroke(Color.islandWatch, lineWidth: espessura)
                    .opacity(pulsando ? 1 : 0.22)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsando)
                    .onAppear { pulsando = true }
            case .idle:
                EmptyView()
            }
        }
        // Por dentro do arco de cota, com folga suficiente para os dois nao se tocarem.
        .padding(metrics.ringStroke * 1.9)
    }
}

private struct DetailBubble: View {
    let snapshot: UsageSnapshot
    let arrowY: CGFloat
    @State private var isPresented = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            BubbleShape(arrowY: arrowY)
                .fill(Color.black)
                .shadow(color: .black.opacity(0.30), radius: 14, x: 0, y: 8)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 9) {
                        ProviderMark(source: snapshot.source).frame(width: 16, height: 16).foregroundStyle(.white)
                        Text("Uso do \(snapshot.displayName)")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    }
                    // Procedencia junto do titulo: e o que separa "a Anthropic disse" de
                    // "eu deduzi" de "voce digitou".
                    Text(snapshot.percentUsed == nil ? snapshot.syncState.label : snapshot.fidelity.etiqueta)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.45))
                }
                if let sessionPercent = snapshot.sessionPercent {
                    UsageBar(title: snapshot.sessionLabel ?? "Sessão atual",
                             percent: sessionPercent, reset: snapshot.resetText)
                }
                if let percent = snapshot.percentUsed {
                    UsageBar(
                        title: snapshot.limitLabel ?? (snapshot.source == .grok ? "Pool semanal" : "Todos os modelos"),
                        percent: percent,
                        reset: snapshot.limitResetText ?? (snapshot.sessionPercent == nil ? snapshot.resetText : "Limite semanal")
                    )
                } else {
                    Text(snapshot.resetText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(snapshot.extraWindows) { janela in
                    UsageBar(title: janela.title, percent: janela.percent, reset: janela.reset)
                }
                if let split = snapshot.hostSplit {
                    HostSplitRow(split: split)
                }
            }
            .padding(IslandLayout.bubblePadding)
            .frame(width: IslandLayout.bubbleWidth, alignment: .topLeading)
            .opacity(isPresented ? 1 : 0)
            .offset(x: isPresented ? 0 : 8)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.22).delay(0.08)) { isPresented = true }
        }
    }
}

enum SessionRow {
    static func cor(_ state: AgentSession.State) -> Color {
        switch state {
        case .waiting: Color.islandWatch
        case .busy: .white
        case .idle: .white.opacity(0.30)
        }
    }
}

private struct UsageBar: View {
    let title: String
    let percent: Double
    let reset: String
    @State private var isFilled = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                Spacer(minLength: 4)
                Text(reset).font(.system(size: 12, weight: .regular)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.islandTrack)
                    Capsule().fill(Color.usageLevel(percent)).frame(width: isFilled ? max(8, geometry.size.width * percent / 100) : 8)
                }
            }
            .frame(height: 7)
            Text("\(Int(percent))% usado").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.48).delay(0.14)) { isFilled = true } }
    }
}

private struct IslandPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(.spring(response: 0.19, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

private struct ProviderMark: View {
    let source: UsageSource

    var body: some View {
        if let image = BrandAsset.image(for: source) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            // Kept only as a resilient fallback if a packaged resource is unavailable.
            switch source {
            case .claude: ClaudeMark()
            case .codex: OpenAIMark()
            case .grok: GrokMark()
            case .opencode: OpenCodeMark()
            }
        }
    }
}

private enum BrandAsset {
    private static let fileNames: [UsageSource: String] = [
        .claude: "claude-white",
        .codex: "codex-white",
        .grok: "grok-white",
        .opencode: "opencode-white"
    ]

    /// The packaged .app keeps the SwiftPM resource bundle in Contents/Resources, but
    /// the generated `Bundle.module` only looks at the .app root and then falls back to
    /// the absolute `.build/` path — under ~/Documents (iCloud) that fallback blocks on a
    /// TCC check when launched by launchd and the window never appears. Look in
    /// Resources first; `Bundle.module` remains for `swift run`.
    private static let bundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("UsageIsland_UsageIsland.bundle"),
           let packaged = Bundle(url: url) { return packaged }
        return Bundle.module
    }()

    // Resolved once: a lookup inside `body` would re-hit the filesystem on every render.
    private static let cache: [UsageSource: NSImage] = {
        var images: [UsageSource: NSImage] = [:]
        for (source, name) in fileNames {
            if let url = bundle.url(forResource: name, withExtension: "png"),
               let image = NSImage(contentsOf: url) { images[source] = image }
        }
        return images
    }()

    static func image(for source: UsageSource) -> NSImage? { cache[source] }
}

private struct ClaudeMark: View {
    var body: some View {
        ZStack {
            ForEach(0..<12, id: \.self) { index in
                Capsule().fill(Color.white).frame(width: 3.2, height: 15).offset(y: -3.4).rotationEffect(.degrees(Double(index) * 30))
            }
            Circle().fill(Color.white).frame(width: 5, height: 5)
        }
    }
}

private struct OpenAIMark: View {
    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2.6, style: .continuous).stroke(Color.white, lineWidth: 2.1)
                    .frame(width: 9, height: 17).offset(y: -3.4).rotationEffect(.degrees(Double(index) * 60))
            }
        }
    }
}

private struct GrokMark: View {
    var body: some View {
        ZStack {
            Capsule().fill(Color.white).frame(width: 3.2, height: 25).rotationEffect(.degrees(42))
            Capsule().fill(Color.white).frame(width: 3.2, height: 25).rotationEffect(.degrees(-42))
            Circle().fill(Color.white).frame(width: 5, height: 5)
        }
    }
}

/// The opencode mark, from its own favicon: a thick outer frame around an inner window
/// whose lower half is filled. Kept as a vector fallback for `opencode-white.png`.
private struct OpenCodeMark: View {
    var body: some View {
        GeometryReader { geometry in
            // The mark's own box is 256x320; scale it to fit and centre it.
            let unit = min(geometry.size.width / 256, geometry.size.height / 320)
            let width = 256 * unit, height = 320 * unit
            let inner = CGRect(x: 64 * unit, y: 64 * unit, width: 128 * unit, height: 192 * unit)
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(CGRect(x: 0, y: 0, width: width, height: height))
                    path.addRect(inner)
                }
                .fill(style: FillStyle(eoFill: true))
                .foregroundStyle(.white)
                Rectangle()
                    .foregroundStyle(Color(red: 0x5A / 255, green: 0x58 / 255, blue: 0x58 / 255))
                    .frame(width: inner.width, height: inner.height / 2)
                    .offset(x: inner.minX, y: inner.midY)
            }
            .frame(width: width, height: height)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

/// A straight strip flush with the screen's right edge. Each end sweeps back into the
/// edge as two tangent arcs — a wide concave sweep closing into a tighter convex corner,
/// with no straight run between them. That asymmetry is what makes the reference read as
/// a cut-out of the screen rather than a docked panel.
private struct RailShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.maxX, h = rect.maxY
        // Read from the rect so the silhouette follows the frame while it animates
        // between the two sizes.
        let flare = w * 0.946
        let theta = 2 * atan(w / flare)
        let radiusSum = flare / sin(theta)
        let r1 = radiusSum * IslandLayout.flareRadiusSplit
        let r2 = radiusSum - r1
        let sweep = Angle.radians(theta)
        let half = Angle.radians(.pi)

        var path = Path()
        path.move(to: CGPoint(x: w, y: 0))
        path.addArc(center: CGPoint(x: w - r1, y: 0), radius: r1,
                    startAngle: .zero, endAngle: sweep, clockwise: false)
        path.addArc(center: CGPoint(x: r2, y: flare), radius: r2,
                    startAngle: sweep - half, endAngle: -half, clockwise: true)
        path.addLine(to: CGPoint(x: 0, y: h - flare))
        path.addArc(center: CGPoint(x: r2, y: h - flare), radius: r2,
                    startAngle: half, endAngle: half - sweep, clockwise: true)
        path.addArc(center: CGPoint(x: w - r1, y: h), radius: r1,
                    startAngle: -sweep, endAngle: .zero, clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// Rounded card with a large arrow on the right whose tip sits at `arrowY`.
private struct BubbleShape: Shape {
    let arrowY: CGFloat

    func path(in rect: CGRect) -> Path {
        let corner = IslandLayout.bubbleCorner
        let depth = IslandLayout.bubbleArrowDepth
        let halfBase = IslandLayout.bubbleArrowBase / 2
        let bodyMaxX = rect.maxX - depth
        let tipY = min(max(arrowY, corner + halfBase), rect.maxY - corner - halfBase)
        var path = Path()
        path.move(to: CGPoint(x: corner, y: 0))
        path.addLine(to: CGPoint(x: bodyMaxX - corner, y: 0))
        path.addQuadCurve(to: CGPoint(x: bodyMaxX, y: corner), control: CGPoint(x: bodyMaxX, y: 0))
        path.addLine(to: CGPoint(x: bodyMaxX, y: tipY - halfBase))
        path.addLine(to: CGPoint(x: rect.maxX, y: tipY))
        path.addLine(to: CGPoint(x: bodyMaxX, y: tipY + halfBase))
        path.addLine(to: CGPoint(x: bodyMaxX, y: rect.maxY - corner))
        path.addQuadCurve(to: CGPoint(x: bodyMaxX - corner, y: rect.maxY), control: CGPoint(x: bodyMaxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: corner, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: 0, y: rect.maxY - corner), control: CGPoint(x: 0, y: rect.maxY))
        path.addLine(to: CGPoint(x: 0, y: corner))
        path.addQuadCurve(to: CGPoint(x: corner, y: 0), control: CGPoint(x: 0, y: 0))
        path.closeSubpath()
        return path
    }
}


/// A linha "de onde saiu a cota" no card.
///
/// Ela e uma barra so, partida em dois, porque as duas fatias somam 100% por construcao —
/// duas barras separadas sugeririam duas medidas independentes, que nao e o caso.
private struct HostSplitRow: View {
    let split: HostSplit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("De onde saiu")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 6)
                Text(split.resumo)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: max(2, geo.size.width * split.macPercent / 100))
                    Capsule()
                        .fill(Color.white.opacity(0.30))
                }
            }
            .frame(height: 4)
            Text(rodape)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(.white.opacity(0.40))
        }
    }

    /// O rodape diz que isto e proporcao de token, nao a conta da Anthropic — e avisa quando
    /// a medida da vps ficou para tras porque o ssh falhou.
    private var rodape: String {
        let base = "proporção em tokens, \(split.dias) dias"
        if let horas = split.vpsAtrasoHoras {
            return base + " · VPS de \(horas)h atrás"
        }
        return base
    }
}
