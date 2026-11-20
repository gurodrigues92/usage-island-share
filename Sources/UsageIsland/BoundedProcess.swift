import Foundation
import Darwin

/// Runs a helper with a deadline and bounded output. Every exit path reaps the child.
enum BoundedProcess {
    struct Result: Sendable {
        let output: Data
        let status: Int32
    }

    static func run(executable: String, arguments: [String], timeout: TimeInterval,
                    outputLimit: Int = 1_048_576) -> Result? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        defer {
            stop(process)
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        // Close our writer so EOF depends only on the child and its descendants.
        try? pipe.fileHandleForWriting.close()
        var descriptor = pollfd(fd: pipe.fileHandleForReading.fileDescriptor,
                                events: Int16(POLLIN), revents: 0)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var output = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while ProcessInfo.processInfo.systemUptime < deadline {
            let ready = poll(&descriptor, 1, 50)
            if ready < 0 { if errno == EINTR { continue }; return nil }
            if ready == 0 {
                if !process.isRunning { return Result(output: output, status: process.terminationStatus) }
                continue
            }
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor.fd, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR { continue }; return nil }
            if count == 0 {
                // A helper can close stdout before it exits; do not wait without a deadline.
                while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                guard !process.isRunning else { return nil }
                return Result(output: output, status: process.terminationStatus)
            }
            guard output.count + count <= outputLimit else { return nil }
            output.append(contentsOf: bytes.prefix(count))
        }
        return nil
    }

    static func stop(_ process: Process) {
        if process.isRunning {
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
    }
}
