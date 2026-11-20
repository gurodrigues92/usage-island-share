import Foundation
import Testing
@testable import UsageIsland

struct OpenCodeFailureTests {
    @Test func expiredKeyHasActionableReasonWithoutEchoingServerText() throws {
        let body = Data(#"{"error":{"code":"api_key_expired","message":"Bearer PRIVATE_KEY /private/secret"}}"#.utf8)
        guard case .failure(let error) = OpenCodeUsageReader.decode(body, status: 401) else { Issue.record("401 must fail"); return }
        #expect(error == .expiredKey)
        #expect(error.needsConnection)
        #expect(error.message.contains("expirou"))
        #expect(!error.message.contains("PRIVATE_KEY"))
        #expect(!error.message.contains("/private"))
    }

    @Test(arguments: [401, 403, 429, 500, 503])
    func httpErrorsCannotBeMistakenForQuotaReadings(_ status: Int) {
        let validUsage = Data(#"{"usage":{"rolling":{"percent":5}}}"#.utf8)
        guard case .failure(let error) = OpenCodeUsageReader.decode(validUsage, status: status) else { Issue.record("HTTP failure cannot publish usage"); return }
        let expected: OpenCodeUsageReader.Failure = switch status {
        case 401: .authentication
        case 403: .permissionDenied
        case 429: .rateLimited
        default: .http(status)
        }
        #expect(error == expected)
    }

    @Test func responseShapeChangeIsDistinctFromAuthenticationAndNetwork() {
        guard case .failure(let error) = OpenCodeUsageReader.decode(Data("{}".utf8), status: 200) else { Issue.record("Invalid body must fail"); return }
        #expect(error == .invalidResponse)
        #expect(!error.needsConnection)
    }

    @Test func expiredKeyRetainsOldReadingUntilValidCredentialSucceeds() throws {
        let date = Date.now.addingTimeInterval(-3 * 86400)
        let reading = OpenCodeUsageReader.Reading(percentUsed: 6, rollingPercent: 2, limitLabel: "Semanal", limitResetText: "", resetText: "", updatedAt: date)
        var snapshot = UsageSnapshot(source: .opencode, percentUsed: nil, sessionPercent: nil, resetText: "", updatedAt: .now, syncState: .loading)
        snapshot.applyOpenCodeResult(.success(reading))
        snapshot.applyOpenCodeResult(.failure(.expiredKey))
        #expect(snapshot.percentUsed == 6)
        #expect(snapshot.lastSuccessfulRead == date)
        #expect(snapshot.syncState == .failed)
        #expect(snapshot.openCodeFailure == .expiredKey)
        #expect(snapshot.statusText().contains("expirou"))
        #expect(snapshot.lastReadText.contains(date.formatted(date: .abbreviated, time: .shortened)))
        #expect(snapshot.isStale())
        #expect(!snapshot.hasBlockedWindow)
        let result = OpenCodeUsageReader.decode(Data(#"{"usage":{"rolling":{"percent":12},"weekly":{"percent":42}}}"#.utf8), status: 200)
        snapshot.applyOpenCodeResult(result)
        #expect(snapshot.percentUsed == 42)
        #expect(snapshot.syncState == .live)
        #expect(snapshot.openCodeFailure == nil)
        #expect(snapshot.failureReason == nil)
        #expect(!snapshot.isStale())
    }
}
