import Foundation
import Testing
@testable import UsageIsland

struct GrokSnapshotTests {
    private func snapshot() -> UsageSnapshot {
        UsageSnapshot(source: .grok, percentUsed: nil, sessionPercent: nil,
                      resetText: "Lendo uso", updatedAt: .distantPast, syncState: .loading)
    }

    @Test func liveUsageChangesWithoutRestart() {
        var value = snapshot()
        for percent in [22.0, 26.0, 100.0, 0.0] {
            let time = Date()
            value.applyGrokReading(.init(weekly: .init(percentUsed: percent, resetsAt: time),
                                         web: nil, updatedAt: time))
            #expect(value.percentUsed == percent)
            #expect(value.updatedAt == time)
            #expect(value.syncState == .live)
            #expect(value.fidelity == .oficial)
        }
    }

    @Test func failureClearsOldNumbersAndRecovers() {
        var value = snapshot()
        let week = GrokWeeklyUsage(percentUsed: 26, resetsAt: .distantFuture)
        let chat = GrokUsageReader.WebLimits(percentUsed: 50, remaining: 20, total: 40, windowSeconds: 7200)
        value.applyGrokReading(.init(weekly: week, web: chat, updatedAt: .now))
        #expect(value.sessionPercent == 50)
        #expect(value.resetText == "20 de 40 restantes")

        let lastSuccess = value.updatedAt
        value.applyGrokReading(.init(weekly: nil, web: chat, updatedAt: .now))
        #expect(value.percentUsed == nil)
        #expect(value.displayPercent == "—")
        #expect(value.sessionPercent == nil)
        #expect(value.sessionLabel == nil)
        #expect(value.limitResetText == nil)
        #expect(value.syncState == .failed)
        #expect(value.updatedAt == lastSuccess)

        value.applyGrokReading(.init(weekly: week, web: nil, updatedAt: .now))
        #expect(value.percentUsed == 26)
        #expect(value.syncState == .live)
        #expect(value.resetText == week.resetText)
        #expect(value.cardRows == 1)
    }

    @Test func missingChatDoesNotHideWeeklyQuota() {
        var value = snapshot()
        value.applyGrokReading(.init(weekly: .init(percentUsed: 26, resetsAt: .distantFuture),
                                     web: nil, updatedAt: .now))
        #expect(value.percentUsed == 26)
        #expect(value.sessionPercent == nil)
        #expect(value.syncState == .live)
    }
}
