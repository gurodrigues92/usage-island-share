import Foundation

/// Successful reads respect the provider's 15-minute cadence; transient failures
/// retry sooner. A renewed credential can wake its own account without waking others.
struct ClaudeRefreshSchedule {
    private struct State {
        var nextAttempt = Date.distantPast
        var revision: Date?
        var failures = 0
    }
    private var accounts: [String: State] = [:]
    func nextAttempt(service: String) -> Date? { accounts[service]?.nextAttempt }

    mutating func reserve(service: String, revision: Date?, now: Date = .now) -> Bool {
        var state = accounts[service] ?? State()
        let renewed = revision != nil && revision != state.revision
        guard renewed || now >= state.nextAttempt else { return false }
        state.revision = revision
        state.nextAttempt = now.addingTimeInterval(900)
        accounts[service] = state
        return true
    }

    mutating func succeeded(service: String, now: Date = .now) {
        var state = accounts[service] ?? State()
        state.failures = 0
        state.nextAttempt = now.addingTimeInterval(900)
        accounts[service] = state
    }

    mutating func failed(service: String, notBefore: Date? = nil, credentialFailure: Bool = false, now: Date = .now) {
        var state = accounts[service] ?? State()
        state.failures += 1
        let delay = credentialFailure ? 900 : min(900, 60 * pow(2, Double(min(state.failures - 1, 4))))
        state.nextAttempt = max(now.addingTimeInterval(delay), notBefore ?? .distantPast)
        accounts[service] = state
    }
}
