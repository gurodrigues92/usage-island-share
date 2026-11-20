import Foundation
import Testing
@testable import UsageIsland

@MainActor
struct DockActivityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var rings: [RingPreference] {
        [.init(id: "Codex", source: .codex, visible: false),
         .init(id: "Claude-personal", source: .claude, accountSlug: "personal", visible: false),
         .init(id: "Claude-work", source: .claude, accountSlug: "work", visible: false)]
    }
    private func session(_ state: AgentSession.State, id: String = "session-1",
                         at: Date, confirmed: Bool = false, heuristic: Bool = false) -> AgentSession {
        .init(id: id, name: "Projeto de teste", detail: "Terminal", state: state,
              waitingFor: state == .waiting ? "Uma resposta" : nil, since: at,
              isHeuristic: heuristic, completionConfirmed: confirmed)
    }

    @Test func firstSnapshotDoesNotReplayHistoricalCompletion() {
        var state = DockActivityState()
        let done = session(.idle, at: now, confirmed: true)
        state.ingest(sessionsByEntryID: ["Codex": [done]], rings: rings, now: now)
        #expect(state.notice == nil)
        #expect(state.temporaryEntryIDs(now: now).isEmpty)
        state.ingest(sessionsByEntryID: ["Codex": [done]], rings: rings, now: now.addingTimeInterval(1))
        #expect(state.notice == nil)
    }

    @Test func confirmedTransitionExpiresNoticeAtEightAndRevealAtSixtySeconds() throws {
        var state = DockActivityState()
        state.ingest(sessionsByEntryID: ["Codex": [session(.busy, at: now)]], rings: rings, now: now)
        let completedAt = now.addingTimeInterval(1)
        let done = session(.idle, at: completedAt, confirmed: true)
        state.ingest(sessionsByEntryID: ["Codex": [done]], rings: rings, now: completedAt)
        let notice = try #require(state.notice)
        #expect(notice.entryID == "Codex")
        #expect(notice.session == done)
        #expect(notice.expiresAt == completedAt.addingTimeInterval(8))
        #expect(state.nextExpiration == completedAt.addingTimeInterval(8))
        #expect(state.temporaryEntryIDs(now: completedAt) == ["Codex"])
        state.expire(now: completedAt.addingTimeInterval(8))
        #expect(state.notice == nil)
        #expect(state.nextExpiration == completedAt.addingTimeInterval(60))
        #expect(state.temporaryEntryIDs(now: completedAt.addingTimeInterval(59)) == ["Codex"])
        state.expire(now: completedAt.addingTimeInterval(60))
        #expect(state.temporaryEntryIDs(now: completedAt.addingTimeInterval(60)).isEmpty)
        #expect(state.nextExpiration == nil)
        #expect(rings.allSatisfy { !$0.visible })
    }

    @Test func missingHeuristicUnconfirmedStaleAndOutOfOrderSessionsDoNotComplete() {
        let invalidCompletions: [[AgentSession]] = [
            [], // A removed or aborted session is not proof of completion.
            [session(.idle, at: now, confirmed: false)],
            [session(.idle, at: now, confirmed: true, heuristic: true)],
            [session(.idle, at: now.addingTimeInterval(-61), confirmed: true)],
            [session(.idle, at: now.addingTimeInterval(30), confirmed: true)],
            [session(.idle, id: "different-session", at: now, confirmed: true)]
        ]
        for invalid in invalidCompletions {
            var state = DockActivityState()
            state.ingest(sessionsByEntryID: ["Codex": [session(.busy, at: now.addingTimeInterval(-60))]], rings: rings, now: now)
            state.ingest(sessionsByEntryID: ["Codex": invalid], rings: rings, now: now)
            #expect(state.notice == nil)
            #expect(state.temporaryEntryIDs(now: now).isEmpty)
        }
        var state = DockActivityState()
        state.ingest(sessionsByEntryID: ["Codex": [session(.busy, at: now, heuristic: true)]], rings: rings, now: now)
        state.ingest(sessionsByEntryID: ["Codex": [session(.idle, at: now, confirmed: true)]], rings: rings, now: now)
        #expect(state.notice == nil)
    }

    @Test func completionIsNotReplayedAfterAcknowledgementOrRepeatedSnapshots() {
        var state = DockActivityState()
        let busy = session(.busy, at: now)
        let done = session(.idle, at: now.addingTimeInterval(1), confirmed: true)
        state.ingest(sessionsByEntryID: ["Codex": [busy]], rings: rings, now: now)
        state.ingest(sessionsByEntryID: ["Codex": [done]], rings: rings, now: now.addingTimeInterval(1))
        state.acknowledge(entryID: "Codex")
        #expect(state.notice == nil)
        #expect(state.temporaryEntryIDs(now: now.addingTimeInterval(2)).isEmpty)
        state.ingest(sessionsByEntryID: ["Codex": [done]], rings: rings, now: now.addingTimeInterval(2))
        #expect(state.notice == nil)
        // Even an old busy record arriving out of order cannot replay the same end.
        state.ingest(sessionsByEntryID: ["Codex": [busy]], rings: rings, now: now.addingTimeInterval(3))
        state.ingest(sessionsByEntryID: ["Codex": [done]], rings: rings, now: now.addingTimeInterval(4))
        #expect(state.notice == nil)
        #expect(state.temporaryEntryIDs(now: now.addingTimeInterval(4)).isEmpty)
    }

    @Test func waitingPreservesExactAccountAndRemainsUntilInputIsResolved() {
        var state = DockActivityState()
        let waiting = session(.waiting, id: "claude.123", at: now)
        state.ingest(sessionsByEntryID: ["Claude-work": [waiting]], rings: rings, now: now)
        #expect(state.waitingEntryIDs == ["Claude-work"])
        #expect(state.temporaryEntryIDs(now: now) == ["Claude-work"])
        #expect(state.nextExpiration == nil)
        #expect(state.notice == nil)
        state.acknowledge(entryID: "Claude-work")
        state.expire(now: now.addingTimeInterval(120))
        #expect(state.waitingEntryIDs == ["Claude-work"])
        state.ingest(sessionsByEntryID: ["Claude-work": [session(.busy, id: "claude.123", at: now.addingTimeInterval(121))]], rings: rings, now: now.addingTimeInterval(121))
        #expect(state.waitingEntryIDs.isEmpty)
        #expect(state.temporaryEntryIDs(now: now.addingTimeInterval(121)).isEmpty)
    }

    @Test func disabledOrRemovedProvidersCannotReappearAndReenableWarmsAgain() {
        var state = DockActivityState()
        let busy = session(.busy, at: now)
        let done = session(.idle, at: now.addingTimeInterval(1), confirmed: true)
        state.ingest(sessionsByEntryID: ["Codex": [busy]], rings: rings, now: now)
        state.ingest(sessionsByEntryID: ["Codex": [done]], rings: rings, now: now.addingTimeInterval(1))
        var disabled = rings
        disabled[0].enabled = false
        state.ingest(sessionsByEntryID: ["Codex": [done]], rings: disabled, now: now.addingTimeInterval(2))
        #expect(state.notice == nil)
        #expect(state.temporaryEntryIDs(now: now.addingTimeInterval(2)).isEmpty)
        state.ingest(sessionsByEntryID: ["Codex": [done]], rings: rings, now: now.addingTimeInterval(3))
        #expect(state.notice == nil)
        state.ingest(sessionsByEntryID: ["unconfigured": [session(.waiting, at: now)]], rings: rings, now: now)
        #expect(state.waitingEntryIDs.isEmpty)
    }

    @Test func dismissOnlyHidesNoticeAndKeepsRecentCompletionAvailable() {
        var state = DockActivityState()
        state.ingest(sessionsByEntryID: ["Codex": [session(.busy, at: now)]], rings: rings, now: now)
        state.ingest(sessionsByEntryID: ["Codex": [session(.idle, at: now, confirmed: true)]], rings: rings, now: now)
        #expect(state.notice != nil)
        state.dismissNotice()
        #expect(state.notice == nil)
        #expect(state.temporaryEntryIDs(now: now) == ["Codex"])
    }

    @Test func claudeUnknownOrMissingStatusIsNotAConfirmedCompletion() throws {
        let base: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "cwd": "/tmp/dock-activity-test"]
        for status in [nil, "unknown", "new-status"] as [String?] {
            var raw = base
            raw["status"] = status
            let value = try #require(ClaudeSessionMonitor.parse(raw))
            #expect(!value.completionConfirmed)
        }
        var raw = base
        raw["status"] = "idle"
        #expect(try #require(ClaudeSessionMonitor.parse(raw)).completionConfirmed)
        raw["tempo"] = "active"
        #expect(try #require(ClaudeSessionMonitor.parse(raw)).completionConfirmed == false)
    }
}
