import Foundation

/// Reads the OpenCode Go plan's own usage endpoint, `GET /zen/go/v1/usage`, with the API key
/// the CLI already stores on disk. The endpoint answers with three windows — rolling, weekly
/// and monthly — each carrying a percentage, a status and a reset instant. It is undocumented
/// (the issues asking for it are still open upstream), so treat a shape change as "no data"
/// rather than guessing.
struct OpenCodeUsageReader {
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
    }

    struct Janela: Sendable {
        let titulo: String
        let percent: Double
        let reset: String
    }

    private struct Window {
        let percent: Double
        let resetsAt: Date?
    }

    static func read() async -> Reading? {
        guard let key = apiKey() else { return nil }
        var request = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/usage")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any] else { return nil }

        guard let rolling = window(usage["rolling"]) else { return nil }
        let weekly = window(usage["weekly"])
        let monthly = window(usage["monthly"])

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

        return Reading(
            percentUsed: binding.window.percent,
            rollingPercent: rolling.percent,
            limitLabel: binding.label,
            limitResetText: resetText(for: binding.window.resetsAt),
            resetText: resetText(for: rolling.resetsAt),
            updatedAt: .now,
            extra: outra
        )
    }

    private static func window(_ value: Any?) -> Window? {
        guard let object = value as? [String: Any] else { return nil }
        // `status: rate-limited` comes with percent 100, but do not depend on that pairing.
        let percent = (object["percent"] as? NSNumber)?.doubleValue
            ?? (object["status"] as? String == "rate-limited" ? 100 : nil)
        guard let percent else { return nil }
        let resetsAt = (object["resetsAt"] as? String).flatMap(parseTimestamp)
        return Window(percent: min(max(percent, 0), 100), resetsAt: resetsAt)
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
