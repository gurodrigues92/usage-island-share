import Foundation

struct GrokWeeklyUsage: Sendable, Equatable {
    let percentUsed: Double
    let resetsAt: Date

    var resetText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "dd/MM HH:mm"
        return "Reinicia \(formatter.string(from: resetsAt))"
    }

    private struct Response: Decodable {
        struct Config: Decodable {
            struct Period: Decodable {
                let type: String
                let start: String
                let end: String
            }
            let creditUsagePercent: Double
            let currentPeriod: Period
        }
        let config: Config
    }

    /// Missing quota fields (including the legacy monthly billing response) are not zero.
    static func parse(_ data: Data, now: Date = .now) -> Self? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let config = response.config
        let formatter = ISO8601DateFormatter()
        func date(_ value: String) -> Date? {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }
        guard config.currentPeriod.type == "USAGE_PERIOD_TYPE_WEEKLY",
              config.creditUsagePercent.isFinite,
              (0...100).contains(config.creditUsagePercent),
              let start = date(config.currentPeriod.start),
              let end = date(config.currentPeriod.end),
              start <= now, now < end else { return nil }
        return Self(percentUsed: config.creditUsagePercent, resetsAt: end)
    }
}
