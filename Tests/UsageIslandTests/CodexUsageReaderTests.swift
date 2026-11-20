import Foundation
import XCTest
@testable import UsageIsland

final class CodexUsageReaderTests: XCTestCase {
    private func helper(_ body: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("codex-fixture")
        try ("#!/usr/bin/python3\n" + body).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file.path
    }

    func testDelayedReplyIsReadWithoutWaitingForHelperExit() throws {
        let executable = try helper("""
        import json, sys, time
        request = json.loads(sys.stdin.readline())
        assert request['method'] == 'initialize'
        sys.stderr.write('diagnostic noise ' * 10000)
        sys.stderr.flush()
        time.sleep(2.2)
        print(json.dumps({'id': 1, 'result': {}}), flush=True)
        assert json.loads(sys.stdin.readline())['method'] == 'initialized'
        request = json.loads(sys.stdin.readline())
        assert request['method'] == 'account/rateLimits/read'
        print(json.dumps({'method': 'account/updated', 'params': {}}), flush=True)
        response = json.dumps({'id': 2, 'result': {'rateLimits': {
            'limitId': 'codex', 'primary': {'usedPercent': 40, 'resetsAt': 1893456000}}}})
        sys.stdout.write(response[:20])
        sys.stdout.flush()
        time.sleep(0.1)
        sys.stdout.write(response[20:] + '\\n')
        sys.stdout.flush()
        time.sleep(60)
        """)
        let start = Date()
        let reading = CodexUsageReader.readSynchronously(executable: executable, timeout: 8)
        XCTAssertEqual(reading?.percentUsed, 40)
        XCTAssertLessThan(Date().timeIntervalSince(start), 7)
    }

    func testHungHelperIsKilledAndDoesNotFreezeRefresh() throws {
        let executable = try helper("""
        import signal, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        time.sleep(60)
        """)
        let start = Date()
        XCTAssertNil(CodexUsageReader.readSynchronously(executable: executable, timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testRPCErrorDoesNotBecomeAUsageReading() throws {
        let executable = try helper("""
        import json, sys
        sys.stdin.readline()
        print(json.dumps({'id': 1, 'result': {}}), flush=True)
        sys.stdin.readline()
        sys.stdin.readline()
        print(json.dumps({'id': 2, 'error': {'code': -1, 'message': 'offline'}}), flush=True)
        """)
        XCTAssertNil(CodexUsageReader.readSynchronously(executable: executable, timeout: 5))
    }

    func testInvalidPercentIsRejected() {
        XCTAssertNil(CodexUsageReader.parse(result: ["rateLimits": ["primary": ["usedPercent": 150]]]))
    }

    func testModelSpecificBlockIsPreservedAtLowUtilization() throws {
        let main: [String: Any] = ["limitId": "codex", "primary": ["usedPercent": 10]]
        let model: [String: Any] = ["limitName": "Model quota", "rateLimitReachedType": "model",
                                    "primary": ["usedPercent": 20], "secondary": ["usedPercent": 30]]
        let reading = try XCTUnwrap(CodexUsageReader.parse(result: ["rateLimits": main,
            "rateLimitsByLimitId": ["codex": main, "model": model]]))
        XCTAssertTrue(reading.blocked)
        XCTAssertFalse(try XCTUnwrap(reading.windows.first { $0.id == "codex-primary" }).blocked)
        XCTAssertTrue(try XCTUnwrap(reading.windows.first { $0.id == "model-primary" }).blocked)
        XCTAssertTrue(try XCTUnwrap(reading.windows.first { $0.id == "model-secondary" }).blocked)
        XCTAssertEqual(reading.percentUsed, 10)
    }
}
