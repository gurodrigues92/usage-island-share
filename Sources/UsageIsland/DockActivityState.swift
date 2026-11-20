import Foundation

struct DockCompletionNotice: Identifiable, Equatable, Sendable {
    let id: String
    let entryID: String
    let session: AgentSession
    let expiresAt: Date
}

/// Ephemeral presentation only. It never changes the user's saved ring visibility,
/// sends system notifications, or treats an absent session as completed work.
struct DockActivityState: Equatable {
    private struct CompletionKey: Hashable {
        let entryID: String
        let sessionID: String
        let since: Date
    }

    private var previous: [String: [String: AgentSession]] = [:]
    private var completionUntil: [String: Date] = [:]
    private var seenCompletions: [CompletionKey: Date] = [:]
    private(set) var waitingEntryIDs: Set<String> = []
    private(set) var notice: DockCompletionNotice?

    /// No timer is needed for waiting sessions or deduplication bookkeeping.
    var nextExpiration: Date? {
        (Array(completionUntil.values) + [notice?.expiresAt].compactMap { $0 }).min()
    }

    /// Receivers must pass their full current map, keyed by the exact configured
    /// account/entry ID. Session prefixes cannot disambiguate multiple accounts.
    mutating func ingest(sessionsByEntryID: [String: [AgentSession]],
                         rings: [RingPreference], now: Date) {
        guard now.timeIntervalSince1970.isFinite else { return }
        expire(now: now)
        let enabled = Set(rings.filter(\.enabled).map(\.id))
        previous = previous.filter { enabled.contains($0.key) }
        completionUntil = completionUntil.filter { enabled.contains($0.key) }
        if let notice, !enabled.contains(notice.entryID) { self.notice = nil }
        waitingEntryIDs = []
        var completions: [DockCompletionNotice] = []

        for entryID in enabled {
            let current = (sessionsByEntryID[entryID] ?? []).reduce(into: [String: AgentSession]()) { rows, session in
                guard !session.id.isEmpty, session.since.timeIntervalSince1970.isFinite,
                      session.since <= now.addingTimeInterval(5) else { return }
                if let old = rows[session.id], old.since > session.since { return }
                rows[session.id] = session
            }
            if current.values.contains(where: { $0.state == .waiting && !$0.isHeuristic }) {
                waitingEntryIDs.insert(entryID)
            }
            // The first snapshot warms the baseline. A matching previously busy
            // session is essential, even when a reader reports a completed event.
            for session in current.values {
                guard let old = previous[entryID]?[session.id], old.state == .busy,
                      !old.isHeuristic, session.state == .idle, session.completionConfirmed,
                      !session.isHeuristic, session.since >= old.since,
                      now.timeIntervalSince(session.since) <= 60 else { continue }
                let key = CompletionKey(entryID: entryID, sessionID: session.id, since: session.since)
                guard seenCompletions[key] == nil else { continue }
                seenCompletions[key] = now
                completionUntil[entryID] = now.addingTimeInterval(60)
                completions.append(.init(id: UUID().uuidString, entryID: entryID,
                                         session: session, expiresAt: now.addingTimeInterval(8)))
            }
            previous[entryID] = current
        }
        if let newest = completions.max(by: {
            if $0.session.since != $1.session.since { return $0.session.since < $1.session.since }
            return ($0.entryID + $0.session.id) < ($1.entryID + $1.session.id)
        }) {
            notice = newest
        }
        if seenCompletions.count > 256 {
            seenCompletions = Dictionary(uniqueKeysWithValues: seenCompletions
                .sorted { $0.value > $1.value }.prefix(256).map { ($0.key, $0.value) })
        }
    }

    mutating func expire(now: Date) {
        guard now.timeIntervalSince1970.isFinite else { return }
        completionUntil = completionUntil.filter { $0.value > now }
        seenCompletions = seenCompletions.filter { now.timeIntervalSince($0.value) < 3600 }
        if let notice, notice.expiresAt <= now { self.notice = nil }
    }

    func temporaryEntryIDs(now: Date) -> Set<String> {
        waitingEntryIDs.union(completionUntil.filter { $0.value > now }.map(\.key))
    }

    /// Acknowledgement clears a completion badge, not an ongoing request for input.
    mutating func acknowledge(entryID: String) {
        completionUntil.removeValue(forKey: entryID)
        if notice?.entryID == entryID { notice = nil }
    }

    mutating func dismissNotice() { notice = nil }
}
