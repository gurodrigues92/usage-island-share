import Foundation

/// Reads the OpenCode Go plan's own usage endpoint, `GET /zen/go/v1/usage`, with the API key
/// the CLI already stores on disk. The endpoint answers with three windows — rolling, weekly
/// and monthly — each carrying a percentage, a status and a reset instant. It is undocumented
/// (the issues asking for it are still open upstream), so treat a shape change as "no data"
/// rather than guessing.
struct OpenCodeUsageReader {
    enum Failure: Error, Equatable, Sendable {
        case missingKey, expiredKey, authentication, permissionDenied, rateLimited, network, invalidResponse
        case http(Int)

        var message: String {
            switch self {
            case .missingKey: "Conecte o OpenCode Go com /connect no OpenCode"
            case .expiredKey: "A chave do OpenCode expirou · crie uma nova no console e substitua com /connect"
            case .authentication: "OpenCode recusou a chave (401) · confira a chave no console e em /connect"
            case .permissionDenied: "A chave não tem acesso ao uso do OpenCode Go (403)"
            case .rateLimited: "OpenCode pediu uma pausa nas consultas · nova tentativa automática"
            case .network: "Sem conexão com o OpenCode · nova tentativa automática"
            case .invalidResponse: "O OpenCode retornou dados de uso incompatíveis"
            case .http(let status): "OpenCode indisponível (HTTP \(status)) · nova tentativa automática"
            }
        }
        var needsConnection: Bool {
            switch self {
            case .missingKey, .expiredKey, .authentication, .permissionDenied: true
            default: false
            }
        }
    }

    struct Reading: Sendable {
        let percentUsed: Double
        let rollingPercent: Double
        let limitLabel: String
        let limitResetText: String
        let resetText: String
        let updatedAt: Date
        /// A outra janela longa — a que nao ficou com o anel.
        ///
        /// Entre semanal e mensal, o anel fica com a que esta mais cheia e a outra sumia da
        /// tela. Ela e informacao boa: saber que a mensal esta em 30 % enquanto a semanal
        /// bate 100 % diz que e so esperar a virada da semana.
        var extra: Janela? = nil
        var blocked: Bool = false
        var windows: [QuotaWindow] = []
        var primaryWindowID: String? = nil
    }

    struct Janela: Sendable {
        let titulo: String
        let percent: Double
        let reset: String
    }

    private struct Window {
        let percent: Double
        let resetsAt: Date?
        let blocked: Bool
    }

    static func read() async -> Result<Reading, Failure> {
        guard let key = apiKey() else { return .failure(.missingKey) }
        var request = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/usage")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await ProviderHTTP.data(for: request, key: "OpenCode")
            guard let response = response as? HTTPURLResponse else { return .failure(.invalidResponse) }
            return decode(data, status: response.statusCode)
        } catch {
            return .failure(await HTTPBackoff.shared.waiting("OpenCode") != nil ? .rateLimited : .network)
        }
    }

    /// Only allowlisted error codes reach the UI. Never echo server messages, keys or paths.
    static func decode(_ data: Data, status: Int) -> Result<Reading, Failure> {
        switch status {
        case 200:
            return parse(data).map { .success($0) } ?? .failure(.invalidResponse)
        case 401:
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = root?["error"] as? [String: Any]
            return .failure(error?["code"] as? String == "api_key_expired" ? .expiredKey : .authentication)
        case 403: return .failure(.permissionDenied)
        case 429: return .failure(.rateLimited)
        default: return .failure(.http(status))
        }
    }

    static func parse(_ data: Data) -> Reading? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any] else { return nil }

        guard let rolling = window(usage["rolling"]) else { return nil }
        let weekly = window(usage["weekly"])
        let monthly = window(usage["monthly"])
        for key in ["weekly", "monthly"] {
            if let raw = usage[key], !(raw is NSNull), window(raw) == nil { return nil }
        }

        // The ring shows whichever window is actually holding you back — the plan stops at the
        // first one to fill, so the highest of the two long windows is the honest number.
        let binding: (label: String, window: Window)
        switch (weekly, monthly) {
        case let (weekly?, monthly?):
            binding = monthly.percent > weekly.percent ? ("Mensal", monthly) : ("Semanal", weekly)
        case let (weekly?, nil):
            binding = ("Semanal", weekly)
        case let (nil, monthly?):
            binding = ("Mensal", monthly)
        case (nil, nil):
            binding = ("Janela atual", rolling)
        }

        let outra: Janela?
        switch (weekly, monthly) {
        case let (weekly?, monthly?):
            let sobra = binding.label == "Mensal" ? ("Semanal", weekly) : ("Mensal", monthly)
            outra = Janela(titulo: sobra.0, percent: sobra.1.percent,
                           reset: resetText(for: sobra.1.resetsAt))
        default:
            outra = nil
        }

        var windows = [QuotaWindow(id: "rolling", title: "Janela curta", percent: rolling.percent,
                                   resetsAt: rolling.resetsAt, duration: 5 * 3600, blocked: rolling.blocked)]
        if let weekly { windows.append(.init(id: "weekly", title: "Semanal", percent: weekly.percent, resetsAt: weekly.resetsAt, duration: 7 * 86400, blocked: weekly.blocked)) }
        if let monthly { windows.append(.init(id: "monthly", title: "Mensal", percent: monthly.percent, resetsAt: monthly.resetsAt, blocked: monthly.blocked)) }
        let primaryID = binding.label == "Mensal" ? "monthly" : binding.label == "Semanal" ? "weekly" : "rolling"
        return Reading(
            percentUsed: binding.window.percent,
            rollingPercent: rolling.percent,
            limitLabel: binding.label,
            limitResetText: resetText(for: binding.window.resetsAt),
            resetText: resetText(for: rolling.resetsAt),
            updatedAt: .now,
            extra: outra,
            blocked: rolling.blocked || (weekly?.blocked ?? false) || (monthly?.blocked ?? false),
            windows: windows, primaryWindowID: primaryID
        )
    }

    private static func window(_ value: Any?) -> Window? {
        guard let object = value as? [String: Any] else { return nil }
        // `status: rate-limited` comes with percent 100, but do not depend on that pairing.
        let percent: Double?
        if let raw = object["percent"], !(raw is NSNull) {
            percent = UsageValidation.percent(json: raw)
        } else {
            percent = object["status"] as? String == "rate-limited" ? 100 : nil
        }
        guard let percent else { return nil }
        let resetsAt = (object["resetsAt"] as? String).flatMap(parseTimestamp)
        return Window(percent: percent, resetsAt: resetsAt,
                      blocked: object["status"] as? String == "rate-limited")
    }

    /// Same lookup order the OpenCode CLI itself uses.
    private static func apiKey() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths: [String] = []
        if let dataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !dataHome.isEmpty {
            paths.append("\(dataHome)/opencode/auth.json")
        }
        paths.append("\(home)/.local/share/opencode/auth.json")
        paths.append("\(home)/Library/Application Support/opencode/auth.json")

        for path in paths {
            guard let data = FileManager.default.contents(atPath: path),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entry = root["opencode-go"] as? [String: Any],
                  let key = entry["key"] as? String, !key.isEmpty else { continue }
            return key
        }
        return nil
    }

    /// The endpoint sends milliseconds, which the plain internet-date formatter rejects.
    private static func parseTimestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func resetText(for date: Date?) -> String {
        guard let date else { return "Reset não informado" }
        let components = Calendar.current.dateComponents([.day, .hour, .minute], from: .now, to: date)
        if let day = components.day, day > 0 { return "Reinicia em \(day)d \(max(0, components.hour ?? 0))h" }
        if let hour = components.hour, hour > 0 { return "Reinicia em \(hour)h" }
        return "Reinicia em \(max(1, components.minute ?? 1))min"
    }
}
