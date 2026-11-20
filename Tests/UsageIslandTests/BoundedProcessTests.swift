import Foundation
import XCTest
@testable import UsageIsland

final class BoundedProcessTests: XCTestCase {
    private func helper(_ body: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("helper")
        try ("#!/usr/bin/python3\n" + body).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file.path
    }

    func testHelperIgnoringTermCannotHoldRefreshForever() throws {
        let file = try helper("import signal,time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\ntime.sleep(60)")
        let start = Date()
        XCTAssertNil(BoundedProcess.run(executable: file, arguments: [], timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testClosedStdoutDoesNotCauseUnboundedWait() throws {
        let file = try helper("import os,signal,time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\nos.close(1)\ntime.sleep(60)")
        let start = Date()
        XCTAssertNil(BoundedProcess.run(executable: file, arguments: [], timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testOutputIsCapturedWithExitStatus() throws {
        let file = try helper("import sys\nprint('fixture-result')\nsys.exit(7)")
        let result = try XCTUnwrap(BoundedProcess.run(executable: file, arguments: [], timeout: 5))
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(String(data: result.output, encoding: .utf8), "fixture-result\n")
    }

    func testExcessiveOutputIsBounded() throws {
        let file = try helper("import sys,time\nsys.stdout.write('x'*100000)\nsys.stdout.flush()\ntime.sleep(60)")
        XCTAssertNil(BoundedProcess.run(executable: file, arguments: [], timeout: 2, outputLimit: 64))
    }
}
