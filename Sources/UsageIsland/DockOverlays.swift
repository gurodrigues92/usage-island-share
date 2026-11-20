import SwiftUI

struct DockEdgeHint: View {
    let visible: Bool
    let attention: Bool
    let reduceMotion: Bool
    @State private var wave = false

    var body: some View {
        ZStack {
            Color.clear
            if visible {
                Capsule().fill(attention ? Color.orange.opacity(0.65) : Color.white.opacity(0.45))
                    .frame(width: 4)
                if attention && !reduceMotion {
                    GeometryReader { proxy in
                        Capsule().fill(.linearGradient(colors: [.clear, .orange, .white, .clear], startPoint: .bottom, endPoint: .top))
                            .frame(width: 4, height: 45)
                            .position(x: proxy.size.width / 2, y: wave ? -25 : proxy.size.height + 25)
                            .onAppear { withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) { wave = true } }
                    }.clipped().allowsHitTesting(false)
                }
            }
        }
        .contentShape(Rectangle())
        .onChange(of: attention) { _, active in if !active { wave = false } }
        .onChange(of: reduceMotion) { _, reduced in if reduced { wave = false } }
        .accessibilityLabel(attention ? "Usage Island oculto: uma sessão espera por você" : "Mostrar Usage Island")
        .help(attention ? "Uma sessão espera por você. Aproxime o ponteiro para abrir a dock." : "Aproxime o ponteiro para mostrar o Usage Island")
    }
}

struct DockCompletionBubble: View {
    let notice: DockCompletionNotice
    let provider: String
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Sessão terminou", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .accessibilityLabel("Dispensar aviso")
            }.font(.system(size: 12, weight: .semibold))
            Text(notice.session.name).font(.system(size: 13, weight: .medium)).lineLimit(2)
            HStack {
                Text(provider).font(.caption).foregroundStyle(.white.opacity(0.65))
                Spacer()
                Button("Abrir sessão", action: open).font(.caption.bold())
            }
        }
        .foregroundStyle(.white).buttonStyle(.plain).padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.black, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.14)))
    }
}

struct DockSessionsSummary: View {
    let activity: SessionActivity
    let open: (AgentSession) -> Void
    let all: () -> Void

    private var ordered: [AgentSession] {
        func priority(_ item: AgentSession) -> Int { item.state == .waiting ? 0 : item.state == .busy ? 1 : 2 }
        return activity.sessions.sorted {
            if priority($0) != priority($1) { return priority($0) < priority($1) }
            return $0.since > $1.since
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(activity.resumo).font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("Ver todas", action: all).font(.system(size: 10))
            }
            ForEach(Array(ordered.prefix(3))) { session in
                Button { open(session) } label: {
                    HStack(alignment: .top, spacing: 7) {
                        Circle().fill(SessionRow.cor(session.state)).frame(width: 6, height: 6).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.name).font(.system(size: 11)).lineLimit(1)
                            Text(session.waitingFor ?? (session.isHeuristic ? "Atividade estimada" : session.state == .busy ? "Trabalhando" : "Sessão aberta"))
                                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.60)).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.forward").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                    }.contentShape(Rectangle())
                }.help("Abrir a aplicação da sessão. Se indisponível, abrir a lista de sessões.")
            }
        }.foregroundStyle(.white).buttonStyle(.plain)
    }
}
