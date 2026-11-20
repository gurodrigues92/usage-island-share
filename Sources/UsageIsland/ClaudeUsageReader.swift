import Foundation

/// Claude Code's existing statusline writes this cache from Anthropic's official
/// `rate_limits.seven_day.used_percentage` payload. Reading it never touches OAuth,
/// cookies, or the network.
struct ClaudeUsageReader {
    struct Reading: Sendable {
        let percentUsed: Double
        let updatedAt: Date
    }

    static func read() -> Reading? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.quota-state")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let fields = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count >= 2,
              let epoch = TimeInterval(fields[0]), epoch.isFinite,
              let percent = UsageValidation.percent(Double(fields[1])) else { return nil }
        let updatedAt = Date(timeIntervalSince1970: epoch)
        // A weekly reset can happen while Claude Code is idle. An old statusline
        // snapshot is less useful than an explicit "awaiting update" state.
        let age = Date().timeIntervalSince(updatedAt)
        guard age >= -60, age < 6 * 60 * 60 else { return nil }
        return Reading(percentUsed: percent, updatedAt: updatedAt)
    }
}
