import Foundation
import Testing
@testable import UsageIsland

private actor CollectorStub {
    let documents: [AnalyticsDocument]
    let failureAt: Int?
    let delay: Duration
    private(set) var calls = 0
    init(_ documents: [AnalyticsDocument], failureAt: Int? = nil, delay: Duration = .zero) {
        self.documents = documents; self.failureAt = failureAt; self.delay = delay
    }
    func read(_ budget: Int) async throws -> AnalyticsDocument {
        calls += 1
        if delay > .zero { try await Task.sleep(for: delay) }
        if calls == failureAt { throw CollectorFailure.failed }
        return documents[min(calls - 1, documents.count - 1)]
    }
}

@MainActor
struct CollectorIntegrationTests {
    private func document(read: Int, complete: Bool, invalid: Int = 0, tails: Int = 0) -> AnalyticsDocument {
        let row = TokenUsageRow(id: "fixture", provider: "Codex", project: "Fixture", model: "fixture-model", day: UsageDay.string(.now),
                                input: read, output: 0, cacheRead: 0, cacheWrite: 0, cacheWrite1h: 0, calls: 1)
        return AnalyticsDocument(rows: [row], incomplete: !complete, updatedAt: Date.now.ISO8601Format(), warnings: [],
                                 progress: .init(filesTotal: 2, filesComplete: complete ? 2 : 1, bytesTotal: 100, bytesRead: read,
                                                 recordsInvalid: invalid, pendingTailFiles: tails))
    }
    private func isolated(_ stub: CollectorStub, policy: CollectorPolicy = .init()) -> (UsageAnalytics, String) {
        let name = "UsageIsland-Collector-" + UUID().uuidString
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (UsageAnalytics(importURL: url.appendingPathComponent("imports.json"), defaults: UserDefaults(suiteName: name)!,
                               remoteURL: url.appendingPathComponent("remote.json"), collector: { try await stub.read($0) }, collectorPolicy: policy), name)
    }

    @Test func completeRefreshContinuesImmediatelyAndExportsOnlyFinalSnapshot() async throws {
        let stub = CollectorStub([document(read: 20, complete: false), document(read: 80, complete: false), document(read: 100, complete: true)])
        let (analytics, suite) = isolated(stub); defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        await analytics.refresh(prices: [], force: true, complete: true)
        #expect(await stub.calls == 3)
        #expect(!analytics.refreshing && !analytics.incomplete)
        #expect(analytics.progress?.bytesRead == 100)
        #expect(analytics.canExportPortableUsage)
        let package = try JSONDecoder().decode(PortableUsage.self, from: analytics.portableData(name: "Fixture Mac"))
        #expect(package.rows.first?.input == 100)
    }

    @Test func backgroundRefreshIsOneBoundedPassAndKeepsExportBlocked() async {
        let stub = CollectorStub([document(read: 20, complete: false), document(read: 100, complete: true)])
        let (analytics, suite) = isolated(stub); defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        await analytics.refresh(prices: [])
        #expect(await stub.calls == 1)
        #expect(analytics.incomplete && !analytics.canExportPortableUsage)
        #expect(analytics.collectionMessage?.contains("Concluir coleta") == true)
    }

    @Test func stalledCollectionStopsWithoutInventingCompletion() async {
        let stub = CollectorStub([document(read: 20, complete: false)])
        let (analytics, suite) = isolated(stub); defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        await analytics.refresh(prices: [], force: true, complete: true)
        #expect(await stub.calls == 4)
        #expect(analytics.incomplete && !analytics.canExportPortableUsage)
        #expect(analytics.collectionMessage?.contains("não avançou") == true)
    }

    @Test func failureAfterPartialPassPreservesCountersAndBlocksExport() async {
        let stub = CollectorStub([document(read: 20, complete: false)], failureAt: 2)
        let (analytics, suite) = isolated(stub); defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        await analytics.refresh(prices: [], force: true, complete: true)
        #expect(await stub.calls == 2)
        #expect(analytics.rows.first?.input == 20)
        #expect(analytics.issue != nil && !analytics.canExportPortableUsage)
        #expect(!analytics.refreshing)
    }

    @Test func cancellingCompleteRefreshAllowsCurrentBatchToCommit() async {
        let stub = CollectorStub([document(read: 20, complete: false)], delay: .milliseconds(30))
        let (analytics, suite) = isolated(stub); defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let task = Task { await analytics.refresh(prices: [], force: true, complete: true) }
        while !analytics.refreshing { await Task.yield() }
        analytics.cancelCollection()
        await task.value
        #expect(await stub.calls == 1)
        #expect(analytics.rows.first?.input == 20)
        #expect(analytics.collectionMessage?.contains("pausada") == true)
        #expect(!analytics.refreshing && !analytics.canExportPortableUsage)
    }

    @Test func passBudgetStopsRunEvenWithContinuousProgress() async {
        let stub = CollectorStub([document(read: 20, complete: false), document(read: 30, complete: false), document(read: 100, complete: true)])
        let (analytics, suite) = isolated(stub, policy: .init(maximumPasses: 2)); defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        await analytics.refresh(prices: [], force: true, complete: true)
        #expect(await stub.calls == 2)
        #expect(analytics.rows.first?.input == 30)
        #expect(analytics.collectionMessage?.contains("limite") == true)
        #expect(!analytics.canExportPortableUsage)
    }

    @Test func partialCoverageCannotBeExportedEvenIfCollectorSaysFinished() async {
        for document in [document(read: 99, complete: true), document(read: 100, complete: true, invalid: 1), document(read: 100, complete: true, tails: 1)] {
            #expect(PortableUsage.exportIssue(for: document) != nil)
        }
    }

    @Test func olderCollectorDocumentStillDecodesAndInvalidProgressIsRejected() throws {
        let old = Data("{\"rows\":[],\"incomplete\":false,\"updatedAt\":\"2026-10-22T00:00:00Z\",\"warnings\":[]}".utf8)
        #expect(try JSONDecoder().decode(AnalyticsDocument.self, from: old).progress == nil)
        var invalid = document(read: 20, complete: false)
        invalid.progress?.bytesRead = 200
        #expect(!invalid.valid)
    }
}
