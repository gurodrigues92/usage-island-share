import Combine
import Foundation

struct ConnectorHealth: Equatable, Sendable {
    var startedAt: Date? = nil
    var finishedAt: Date? = nil
    var duration: TimeInterval? = nil
    var nextAttempt: Date? = nil
    var error: String? = nil
    var inFlight = false
}

actor HTTPBackoff {
    static let shared = HTTPBackoff()
    private var until: [String: Date] = [:]
    private let defaults: UserDefaults
    init(suiteName: String? = nil) {
        defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        if let stored = defaults.dictionary(forKey: "usageIsland.httpBackoff.v1") {
            for (key, value) in stored {
                if let seconds = value as? Double, seconds.isFinite, (0...40_000_000_000).contains(seconds) { until[key] = Date(timeIntervalSince1970: seconds) }
            }
        }
    }
    func waiting(_ key: String, now: Date = .now) -> Date? { until[key].flatMap { $0 > now ? $0 : nil } }
    func failed(_ key: String, retryAfter: String?, now: Date = .now) {
        let seconds = retryAfter.flatMap(Double.init).flatMap { $0.isFinite && (0...30 * 86400).contains($0) ? $0 : nil }
        let parsed: Date? = {
            guard let retryAfter else { return nil }
            let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
            format.timeZone = TimeZone(secondsFromGMT: 0); format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return format.date(from: retryAfter)
        }()
        until[key] = max(now.addingTimeInterval(max(60, seconds ?? 0)), parsed ?? now)
        defaults.set(until.mapValues(\.timeIntervalSince1970), forKey: "usageIsland.httpBackoff.v1")
    }
}

enum ProviderHTTP {
    static func data(for request: URLRequest, key: String) async throws -> (Data, URLResponse) {
        if await HTTPBackoff.shared.waiting(key) != nil { throw URLError(.resourceUnavailable) }
        let result = try await URLSession.shared.data(for: request)
        if let http = result.1 as? HTTPURLResponse, http.statusCode == 429 {
            await HTTPBackoff.shared.failed(key, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        }
        return result
    }
}

struct ServiceHealth: Equatable, Sendable {
    var summary: String
    var incident: Bool
    var capturedAt: Date
}

@MainActor
final class ServiceStatus: ObservableObject {
    @Published private(set) var values: [UsageSource: ServiceHealth] = [:]
    private var inFlight = false
    private var lastAttempt = Date.distantPast
    func refresh(enabled: Bool) async {
        guard enabled, !inFlight, Date().timeIntervalSince(lastAttempt) >= 300 else { return }
        inFlight = true; lastAttempt = .now; defer { inFlight = false }
        let feeds: [(UsageSource, String)] = [(.codex, "https://status.openai.com/api/v2/status.json"),
                                             (.claude, "https://status.claude.com/api/v2/status.json")]
        for (source, url) in feeds {
            var request = URLRequest(url: URL(string: url)!); request.timeoutInterval = 10
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let health = Self.parse(data) else { continue }
                values[source] = health
            } catch { /* Keep the timestamp of the previous status, never label it fresh. */ }
        }
    }
    nonisolated static func parse(_ data: Data, now: Date = .now) -> ServiceHealth? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = root["status"] as? [String: Any], let indicator = status["indicator"] as? String,
              ["none", "minor", "major", "critical"].contains(indicator) else { return nil }
        return .init(summary: indicator == "none" ? "Serviço operacional" : "Provedor reporta um incidente",
                     incident: indicator != "none", capturedAt: now)
    }
}
