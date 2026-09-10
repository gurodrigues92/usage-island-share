import AppKit
import Combine
import Darwin
import Foundation

/// Uma sessao de agente viva, do jeito que a ilha precisa mostrar.
struct AgentSession: Identifiable, Equatable {
    enum State: Equatable {
        /// Trabalhando agora.
        case busy
        /// Parada esperando voce — o unico estado em que a ilha esta pedindo algo.
        case waiting
        case idle
    }

    let id: String
    /// O nome da conversa, como o Claude Code o escreve.
    let name: String
    /// A segunda linha, mais quieta: onde ela roda.
    let detail: String
    let state: State
    /// Preenchido quando `waiting`: o que ela quer.
    let waitingFor: String?
    let since: Date
}

/// O resumo que o anel desenha: de todas as sessoes vivas, a unica coisa que vale um relance.
struct SessionActivity: Equatable {
    enum State: Equatable { case working, waiting, idle }

    let state: State
    let sessions: [AgentSession]

    /// Nil quando nao ha nada rodando — o indicador some, em vez de ficar ali dizendo nada.
    init?(sessions: [AgentSession]) {
        guard !sessions.isEmpty else { return nil }
        self.sessions = sessions
        // Esperando ganha de ocupado: e o unico estado que quer algo de voce.
        if sessions.contains(where: { $0.state == .waiting }) { state = .waiting }
        else if sessions.contains(where: { $0.state == .busy }) { state = .working }
        else { state = .idle }
    }

    var waiting: [AgentSession] { sessions.filter { $0.state == .waiting } }
    var busy: [AgentSession] { sessions.filter { $0.state == .busy } }

    var resumo: String {
        switch state {
        case .waiting: return waiting.count == 1 ? "1 sessão esperando você" : "\(waiting.count) sessões esperando você"
        case .working: return busy.count == 1 ? "1 sessão trabalhando" : "\(busy.count) sessões trabalhando"
        case .idle: return sessions.count == 1 ? "1 sessão aberta" : "\(sessions.count) sessões abertas"
        }
    }
}

/// Um pid ainda esta vivo — e ainda e o *mesmo* processo?
///
/// Uma sessao que morre de mau jeito deixa o arquivo dela para tras dizendo `busy` para
/// sempre, entao nao da para acreditar no arquivo. E o pid sozinho tambem nao basta numa
/// maquina de meses no ar: pid se recicla, e um reciclado ressuscitaria sessao morta.
/// Comparar o instante de inicio resolve.
enum ProcessLiveness {
    /// Larga o bastante para absorver o intervalo entre o processo subir e a sessao se
    /// registrar, apertada o bastante para nenhum pid reciclado passar.
    private static let toleranciaDeReuso: TimeInterval = 5 * 60

    static func isAlive(pid: Int32, startedAt: Date?) -> Bool {
        guard exists(pid: pid) else { return false }
        guard let startedAt, let real = startTime(pid: pid) else {
            // Sem como provar nem desmentir: confiar no pid e melhor que esconder uma
            // sessao que provavelmente existe.
            return true
        }
        return abs(real.timeIntervalSince(startedAt)) < toleranciaDeReuso
    }

    private static func exists(pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM   // existe, e de outro dono
    }

    static func startTime(pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let inicio = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(inicio.tv_sec) + Double(inicio.tv_usec) / 1_000_000)
    }
}

/// Le `~/.claude/sessions`, onde o Claude Code escreve um arquivo por processo vivo, e
/// publica o que de fato esta rodando.
///
/// A pasta e **observada**, nao consultada de tempos em tempos: o Claude Code reescreve o
/// arquivo no instante em que muda de estado, entao "acabou de terminar" aparece na hora.
/// Um relogio lento roda ao lado so para notar processo que morreu sem encostar na pasta —
/// isso nenhum evento de arquivo vai contar.
///
/// Formato lido do codenotch (MIT, github.com/vinzdg/codenotch — `ClaudeSessionMonitor`),
/// com suporte aos estados busy, idle, waiting e ao indicador tempo: blocked.
@MainActor
final class ClaudeSessionMonitor: ObservableObject {
    @Published private(set) var activity: SessionActivity?

    private let directory: URL
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var timer: Timer?
    private var debounce: DispatchWorkItem?

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")) {
        self.directory = directory
    }

    func start() {
        rescan()
        watch()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func watch() {
        descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }   // pasta ainda nao existe; o relogio cobre
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.agendarRescan() }
        }
        source.setCancelHandler { [descriptor] in if descriptor >= 0 { close(descriptor) } }
        source.resume()
        self.source = source
    }

    /// Uma mudanca de estado gera varios eventos de arquivo; junte-os.
    private func agendarRescan() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rescan() }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func rescan() {
        let novo = SessionActivity(sessions: Self.read(directory: directory))
        guard novo != activity else { return }   // nao sacudir o SwiftUI a toa
        activity = novo
    }

    static func read(directory: URL) -> [AgentSession] {
        let nomes = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return nomes
            .filter { $0.hasSuffix(".json") }
            .compactMap { nome -> AgentSession? in
                let url = directory.appendingPathComponent(nome)
                guard let data = try? Data(contentsOf: url),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sessao = parse(json) else { return nil }
                return sessao
            }
            .sorted { $0.since > $1.since }
    }

    /// Decodificado com folga de proposito: o arquivo e escrito por outro programa, no ritmo
    /// de lancamento dele, e um campo desconhecido nunca pode custar uma sessao que daria
    /// para mostrar.
    static func parse(_ json: [String: Any]) -> AgentSession? {
        guard let pid = (json["pid"] as? NSNumber)?.int32Value,
              let cwd = json["cwd"] as? String else { return nil }

        let startedAt: Date?
        if let ms = (json["startedAt"] as? NSNumber)?.doubleValue {
            startedAt = Date(timeIntervalSince1970: ms / 1000)
        } else {
            startedAt = (json["procStart"] as? String).flatMap(parseProcStart)
        }
        guard ProcessLiveness.isAlive(pid: pid, startedAt: startedAt) else { return nil }

        let bruto = json["status"] as? String
        let tempo = json["tempo"] as? String
        let estado: AgentSession.State
        switch (tempo, bruto) {
        case ("blocked", _), (_, "waiting"): estado = .waiting
        case ("active", _), (_, "busy"):     estado = .busy
        default:                             estado = .idle
        }

        let ms = (json["statusUpdatedAt"] as? NSNumber)?.doubleValue
            ?? (json["updatedAt"] as? NSNumber)?.doubleValue
        let pasta = (cwd as NSString).lastPathComponent
        return AgentSession(
            id: "claude.\(pid)",
            name: (json["name"] as? String) ?? pasta,
            detail: "\(superficie(json["entrypoint"] as? String)) · \(pasta)",
            state: estado,
            waitingFor: (json["waitingFor"] as? String) ?? (json["needs"] as? String),
            since: ms.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date())
    }

    static func superficie(_ entrypoint: String?) -> String {
        switch entrypoint {
        case "claude-desktop", "claude-desktop-3p": "Desktop"
        case "claude-vscode": "VS Code"
        case "local-agent": "Agente"
        default: "Terminal"
        }
    }

    /// `procStart` vem como "Mon Jan  1 00:00:00 2024" — um ctime, em **UTC**, com o dia do
    /// mes preenchido com espaco quando tem um digito so.
    static func parseProcStart(_ texto: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let colapsado = texto.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return formatter.date(from: colapsado)
    }
}
