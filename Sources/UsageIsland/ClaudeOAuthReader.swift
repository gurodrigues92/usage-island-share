import Foundation
import Security

/// O uso do Claude lido no mesmo lugar de onde o proprio `/usage` do Claude Code tira:
/// `GET /api/oauth/usage`, autenticado com o token OAuth que o Claude Code guarda no
/// keychain de login.
///
/// Isto substitui a leitura do `~/.claude/.quota-state`, que so era reescrito enquanto
/// havia sessao do Claude Code viva — com tudo parado o numero congelava e nada na tela
/// dizia isso. Aqui a fonte e a Anthropic, entao o numero esta certo mesmo com a maquina
/// ociosa, e vem com as janelas que o cache nunca teve: a sessao de 5 h e os limites
/// semanais por modelo.
///
/// Estrutura copiada do codenotch (MIT, github.com/vinzdg/codenotch — `ClaudeCredentials`
/// e `ClaudeOAuthProvider`), inclusive a parte que mais importa e que nao se descobre
/// lendo a documentacao: **o Claude Code cria um item novo no keychain a cada rotacao de
/// token em vez de atualizar o que existe**, entao uma conta usada ha meses acumula varios
/// sob o mesmo `service`. Pedir `kSecMatchLimitOne` devolve um deles sem ordem nenhuma —
/// pode ser um expirado, com o token bom ao lado. Por isso a busca aqui enumera todos por
/// atributo e escolhe o mais recente.
enum ClaudeOAuthReader {

    // MARK: - Keychain

    /// Perguntar *sobre* um item do keychain sem pedir o que tem dentro.
    ///
    /// O controle de acesso de um item de outro app guarda o **dado**, nao os atributos:
    /// `kSecReturnAttributes` nunca levanta o dialogo de permissao, `kSecReturnData` pode
    /// levantar sempre. E o que torna barato conferir a data de modificacao a todo momento
    /// e caro so o passo final.
    struct KeychainMatch {
        let modifiedAt: Date?
        let persistentRef: Data
    }

    static func newestItem(service: String) -> KeychainMatch? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecReturnPersistentRef: true,
            kSecMatchLimit: kSecMatchLimitAll
        ] as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        // Um unico item volta como dicionario, nao como array de um.
        let items = (result as? [[CFString: Any]]) ?? (result as? [CFString: Any]).map { [$0] } ?? []
        return items
            .compactMap { item -> KeychainMatch? in
                guard let ref = item[kSecValuePersistentRef] as? Data else { return nil }
                return KeychainMatch(modifiedAt: item[kSecAttrModificationDate] as? Date, persistentRef: ref)
            }
            .max { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }
    }

    struct Credentials {
        let accessToken: String
        let expiresAt: Date
        /// "max", "pro"… o plano a que as leituras se referem.
        let plan: String?
        var isExpired: Bool { expiresAt <= Date() }
    }

    enum CredentialFailure: Error {
        /// Nao ha item nenhum: o Claude Code nunca entrou nessa conta.
        case ausente
        /// O item existe e o macOS recusou entregar — o dialogo foi negado, ou este app
        /// nao esta na lista de acesso. Dizer "faca login" aqui manda consertar o que nao
        /// esta quebrado.
        case recusado(OSStatus)
        /// Existe e venceu. Quem renova e o Claude Code, de proposito: criar um token novo
        /// seria escrever uma credencial que nao e nossa e disputar a rotacao com o dono.
        case vencido
    }

    /// A credencial lida uma vez e guardada ate o token vencer ou o item mudar de data.
    ///
    /// Sem isto o app pedia a chave a cada volta do laco, e cada pedido e um dialogo em
    /// potencial: uma leitura por minuto vira uma fila de dialogos empilhados na tela se a
    /// primeira nao for respondida. A data de modificacao do item se le de graca e sem
    /// dialogo (`kSecReturnAttributes`), entao ela e quem decide quando vale a pena pagar a
    /// leitura de verdade — e um token que o Claude Code acabou de rotacionar entra na hora,
    /// sem depender de relogio nenhum.
    actor CredentialCache {
        private var guardada: Credentials?
        private var lidoEm: Date?
        /// Uma leitura de cada vez: enquanto o dialogo esta aberto, o `SecItemCopyMatching`
        /// nao volta, e comecar outra so empilha dialogo.
        private var lendo = false

        func valor(service: String, ler: (String) throws -> Credentials) throws -> Credentials {
            let carimbo = ClaudeOAuthReader.newestItem(service: service)?.modifiedAt
            if let guardada, !guardada.isExpired, carimbo == lidoEm {
                return guardada
            }
            guard !lendo else {
                // Ha um pedido em curso (dialogo aberto, provavelmente). Devolver o que
                // temos, mesmo vencido, e melhor que abrir um segundo dialogo.
                if let guardada { return guardada }
                throw CredentialFailure.recusado(errSecInteractionNotAllowed)
            }
            lendo = true
            defer { lendo = false }
            let fresca = try ler(service)
            guardada = fresca
            lidoEm = carimbo
            return fresca
        }

        func esquecer() {
            guardada = nil
            lidoEm = nil
        }
    }

    static let cache = CredentialCache()

    static func readCredentials(service: String) throws -> Credentials {
        guard let winner = newestItem(service: service) else { throw CredentialFailure.ausente }

        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecValuePersistentRef: winner.persistentRef,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &item)

        guard status == errSecSuccess, let data = item as? Data else {
            // -25320 (`errSecInDarkWake`) e a maquina recem-acordada: desperta o bastante
            // para rodar tarefa de fundo, nao o bastante para mostrar dialogo. Nao e conta
            // com problema, e "agora nao" — some sozinho na proxima volta.
            throw CredentialFailure.recusado(status)
        }

        struct Payload: Decodable {
            struct OAuth: Decodable {
                let accessToken: String
                /// Milissegundos desde a epoca.
                let expiresAt: Double
                let subscriptionType: String?
            }
            let claudeAiOauth: OAuth
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let payload = try? decoder.decode(Payload.self, from: data) else {
            throw CredentialFailure.ausente
        }
        return Credentials(
            accessToken: payload.claudeAiOauth.accessToken,
            expiresAt: Date(timeIntervalSince1970: payload.claudeAiOauth.expiresAt / 1000),
            plan: payload.claudeAiOauth.subscriptionType
        )
    }

    // MARK: - Endpoint

    /// Uma janela de limite, ja com o rotulo em portugues.
    struct Window: Equatable {
        let kind: String
        let label: String
        let percent: Double
        let resetsAt: Date?
        /// A janela que esta pegando agora, segundo a propria Anthropic.
        let isActive: Bool
        let severity: String?
    }

    struct Reading {
        let windows: [Window]
        let plan: String?
        let updatedAt: Date

        var session: Window? { windows.first { $0.kind == "session" } }
        /// O que vai no anel: o semanal geral, "todos os modelos".
        ///
        /// O anel mantém a mesma escala semanal. Limites por modelo aparecem no cartão.
        var geral: Window? {
            windows.first { $0.kind == "weekly_all" } ?? binding
        }
        /// O limite que de fato manda: o que a Anthropic marca como ativo; sem marca, o
        /// semanal mais alto. Continua servindo de reserva quando nao ha semanal geral.
        var binding: Window? {
            windows.first { $0.isActive && $0.kind != "session" }
                ?? windows.filter { $0.kind != "session" }.max { $0.percent < $1.percent }
        }
        var weeklies: [Window] { windows.filter { $0.kind != "session" } }
    }

    enum ReadFailure: Error {
        case credencial(CredentialFailure)
        case rede(Error)
        case http(Int)
        /// Pediram para desacelerar; segura ate a data.
        case limiteDeTaxa(ate: Date)
    }

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// 429 seguidos dobram a espera. O endpoint responde `Retry-After: 0`, que obedecido ao
    /// pe da letra e como se continua no limite de taxa.
    private static let backoff = Backoff()

    /// A punicao sobrevive ao relancamento do app, de proposito.
    ///
    /// Persiste a próxima tentativa e o número de falhas no UserDefaults para evitar
    /// novas requisições durante a espera após reiniciar o aplicativo.
    actor Backoff {
        private let chaveAte = "usageIsland.claudeBackoffAte"
        private let chaveSeguidos = "usageIsland.claudeBackoffSeguidos"

        private var until: Date? {
            get { UserDefaults.standard.object(forKey: chaveAte) as? Date }
            set { UserDefaults.standard.set(newValue, forKey: chaveAte) }
        }
        private var seguidos: Int {
            get { UserDefaults.standard.integer(forKey: chaveSeguidos) }
            set { UserDefaults.standard.set(newValue, forKey: chaveSeguidos) }
        }

        func esperando() -> Date? {
            guard let until, until > Date() else { return nil }
            return until
        }

        func punir(sugestao: TimeInterval?) -> Date {
            seguidos += 1
            let piso: TimeInterval = 60
            let teto: TimeInterval = 15 * 60
            // O endpoint responde `Retry-After: 0`, que obedecido ao pe da letra e retentar
            // na hora — que e como se continua no limite de taxa. A sugestao dele so pode
            // levantar o piso, nunca abaixa-lo.
            let dobrado = piso * pow(2, Double(min(seguidos, 4)))
            let espera = min(teto, max(dobrado, sugestao ?? 0))
            let quando = Date().addingTimeInterval(espera)
            until = quando
            return quando
        }

        func perdoar() {
            until = nil
            seguidos = 0
        }
    }

    static func read(service: String = defaultService) async throws -> Reading {
        if let until = await backoff.esperando() { throw ReadFailure.limiteDeTaxa(ate: until) }

        let credentials: Credentials
        do {
            credentials = try await cache.valor(service: service) { try readCredentials(service: $0) }
        } catch let failure as CredentialFailure {
            throw ReadFailure.credencial(failure)
        }
        guard !credentials.isExpired else { throw ReadFailure.credencial(.vencido) }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ReadFailure.rede(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 429 {
            let quando = await backoff.punir(sugestao: retryAfter(from: response))
            throw ReadFailure.limiteDeTaxa(ate: quando)
        }
        if status == 401 || status == 403 {
            // Aceito e recusado: o token vale para outra conta, ou foi revogado. A copia em
            // maos esta errada mesmo sem ter vencido — e o que trocar de conta parece daqui.
            await cache.esquecer()
            throw ReadFailure.credencial(.vencido)
        }
        guard (200..<300).contains(status) else { throw ReadFailure.http(status) }
        await backoff.perdoar()

        let payload = try decodeUsage(data)
        return Reading(windows: payload, plan: credentials.plan, updatedAt: .now)
    }

    static func retryAfter(from response: URLResponse?) -> TimeInterval? {
        guard let header = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces) else { return nil }
        if let segundos = TimeInterval(header) { return max(0, segundos) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header).map { max(0, $0.timeIntervalSinceNow) }
    }

    // MARK: - Resposta

    /// `limits` e a forma que cresce sozinha — ganha `kind` novo conforme a Anthropic cria —
    /// entao e a preferida. As duas janelas nomeadas (`five_hour`, `seven_day`) entram como
    /// complemento e nao como alternativa: o esquema do proprio Claude Code diz que um item
    /// de `limits` so existe "enquanto a API o reporta e o `resets_at` nao passou", ou seja,
    /// a janela some de `limits` justo quando vira — que e quando alguem esta olhando.
    static func decodeUsage(_ data: Data) throws -> [Window] {
        struct Escopo: Decodable {
            struct Modelo: Decodable { let displayName: String? }
            let model: Modelo?
        }
        struct Limite: Decodable {
            let kind: String
            let percent: Double
            let resetsAt: Date?
            let isActive: Bool?
            let severity: String?
            let scope: Escopo?
        }
        struct Janela: Decodable {
            let utilization: Double?
            let resetsAt: Date?
        }
        struct Resposta: Decodable {
            let limits: [Limite]?
            let fiveHour: Janela?
            let sevenDay: Janela?
        }

        let resposta = try decoder.decode(Resposta.self, from: data)
        var windows = (resposta.limits ?? []).map { limite in
            Window(kind: limite.kind,
                   label: label(kind: limite.kind, modelo: limite.scope?.model?.displayName),
                   percent: limite.percent,
                   resetsAt: limite.resetsAt,
                   isActive: limite.isActive ?? false,
                   severity: limite.severity)
        }
        func completar(_ janela: Janela?, kind: String, label: String) {
            guard let janela, let uso = janela.utilization,
                  !windows.contains(where: { $0.kind == kind }) else { return }
            windows.append(Window(kind: kind, label: label, percent: uso,
                                  resetsAt: janela.resetsAt, isActive: false, severity: nil))
        }
        completar(resposta.fiveHour, kind: "session", label: "Sessão atual")
        completar(resposta.sevenDay, kind: "weekly_all", label: "Todos os modelos")
        return windows.sorted { ordem($0) < ordem($1) }
    }

    private static func ordem(_ w: Window) -> Int {
        if w.kind == "session" { return 0 }
        if w.kind == "weekly_all" { return 1 }
        return 2
    }

    /// `weekly_scoped` sozinho nao diz nada — o que importa e de qual modelo e o teto, e isso
    /// mora em `scope.model.display_name`.
    static func label(kind: String, modelo: String?) -> String {
        switch kind {
        case "session": return "Sessão atual"
        case "weekly_all": return "Todos os modelos"
        case "weekly_opus": return "Opus semanal"
        case "weekly_sonnet": return "Sonnet semanal"
        case "weekly_scoped": return modelo.map { "\($0) semanal" } ?? "Limite por modelo"
        default:
            let limpo = kind.replacingOccurrences(of: "weekly_", with: "")
                .replacingOccurrences(of: "_", with: " ")
            return modelo ?? limpo.prefix(1).uppercased() + limpo.dropFirst()
        }
    }

    static let defaultService = "Claude Code-credentials"

    /// Exibe o horário de renovação no fuso atual do sistema, com dia da semana se necessário.
    static func resetTexto(_ quando: Date?) -> String {
        guard let quando else { return "sem prazo" }
        guard quando > Date() else { return "reiniciando" }
        var calendario = Calendar(identifier: .gregorian)
        let fuso = TimeZone.current
        calendario.timeZone = fuso
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.timeZone = fuso
        formatter.dateFormat = calendario.isDateInToday(quando) ? "HH'h'mm" : "EEE HH'h'mm"
        return "reinicia " + formatter.string(from: quando)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // As datas vem com fracao de segundo e deslocamento, que o `.iso8601` puro recusa.
        // Os formatadores nascem dentro do closure porque `ISO8601DateFormatter` nao e
        // `Sendable` e capturar um de fora e o tipo de compartilhamento que o compilador
        // avisa e que da corrida em uso concorrente.
        decoder.dateDecodingStrategy = .custom { decoder in
            let comFracao = ISO8601DateFormatter()
            comFracao.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let simples = ISO8601DateFormatter()
            simples.formatOptions = [.withInternetDateTime]
            let texto = try decoder.singleValueContainer().decode(String.self)
            if let data = comFracao.date(from: texto) ?? simples.date(from: texto) { return data }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "data ilegivel \(texto)"))
        }
        return decoder
    }()
}
