import Foundation
import Testing
@testable import UsageIsland

struct GrokWeeklyUsageTests {
    private let now = Date(timeIntervalSince1970: 1_704_326_400) // 2024-01-04 UTC

    private func payload(percent: String = "22", type: String = "USAGE_PERIOD_TYPE_WEEKLY",
                         start: String = "2024-01-01T12:00:00.123456+00:00",
                         end: String = "2024-01-08T12:00:00.123456+00:00") -> Data {
        Data("""
        {"config":{"creditUsagePercent":\(percent),"currentPeriod":{
        "type":"\(type)","start":"\(start)","end":"\(end)"}}}
        """.utf8)
    }

    @Test func readsProviderQuotaAndReset() throws {
        let usage = try #require(GrokWeeklyUsage.parse(payload(), now: now))
        #expect(usage.percentUsed == 22)
        #expect(abs(usage.resetsAt.timeIntervalSince1970 - 1_704_715_200.123456) < 0.001)
    }

    @Test(arguments: ["0", "100", "22.75"])
    func acceptsMeasuredPercentages(_ percent: String) {
        #expect(GrokWeeklyUsage.parse(payload(percent: percent), now: now)?.percentUsed == Double(percent))
    }

    @Test(arguments: ["-1", "101", "null", "true", "\"22\""])
    func rejectsInvalidPercentages(_ percent: String) {
        #expect(GrokWeeklyUsage.parse(payload(percent: percent), now: now) == nil)
    }

    @Test func missingOrLegacyBillingIsNotZero() {
        for json in ["{}", "{\"error\":\"unavailable\"}", "{\"config\":{\"used\":{\"val\":198},\"monthlyLimit\":{\"val\":0}}}"] {
            #expect(GrokWeeklyUsage.parse(Data(json.utf8), now: now) == nil)
        }
        #expect(GrokWeeklyUsage.parse(payload(type: "USAGE_PERIOD_TYPE_MONTHLY"), now: now) == nil)
    }

    @Test func rejectsExpiredFutureAndMalformedPeriods() {
        #expect(GrokWeeklyUsage.parse(payload(end: "2024-01-03T00:00:00Z"), now: now) == nil)
        #expect(GrokWeeklyUsage.parse(payload(start: "2024-01-05T00:00:00Z"), now: now) == nil)
        #expect(GrokWeeklyUsage.parse(payload(end: "unknown"), now: now) == nil)
    }

    @Test func acceptsDatesWithoutFractionalSeconds() {
        #expect(GrokWeeklyUsage.parse(payload(start: "2024-01-01T12:00:00Z", end: "2024-01-08T12:00:00Z"), now: now) != nil)
    }
}
