import Foundation
import Darwin

struct CodexUsageReader {
    struct Reading: Sendable {
        let percentUsed: Double
        let resetText: String
        let updatedAt: Date
        /// Os tetos por modelo, alem do limite geral.
        ///
        /// A resposta do `app-server` carrega um `rateLimitsByLimitId` com uma entrada por
        /// modelo, cada uma com janela curta e semanal, e a ilha lia so o `primary` do bloco
        /// geral. E o mesmo problema que o card do Claude ja tinha: um teto por modelo perto
        /// do fim nao pode ficar escondido atras de um total confortavel.
        var extras: [Janela] = []
        var limitLabel: String = "Janela atual"
        var blocked: Bool = false
        var windows: [QuotaWindow] = []
        var primaryWindowID: String? = nil
    }

    struct Janela: Sendable {
        let id: String
        let titulo: String
        let percent: Double
        let reset: String
        var resetsAt: Date? = nil
        var duration: TimeInterval? = nil
        var blocked: Bool = false
    }

    static func read(directory: String? = nil) async -> Reading? {
        await Task.detached(priority: .utility) { readSynchronously(directory: directory) }.value
    }

    static func readSynchronously(executable override: String? = nil, timeout: TimeInterval = 15, directory: String? = nil) -> Reading? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Prefer the native CLI shipped with the desktop app: the terminal wrapper can
        // require Node/PATH and can lag behind the protocol used by the desktop account.
        let candidates = override.map { [$0] } ?? [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        if let directory {
            process.arguments = ["app-server", "--listen", "stdio://", "-c", "cli_auth_credentials_store=\"file\""]
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = directory
            process.environment = environment
        }
        process.standardInput = input
        process.standardOutput = output
        // A pipe that is never drained can itself block a noisy helper.
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }
        defer {
            try? input.fileHandleForWriting.close()
            BoundedProcess.stop(process)
            try? output.fileHandleForReading.close()
        }

        func send(_ object: [String: Any]) -> Bool {
            guard let data = try? JSONSerialization.data(withJSONObject: object),
                  let line = String(data: data, encoding: .utf8)?.appending("\n").data(using: .utf8) else { return false }
            do { try input.fileHandleForWriting.write(contentsOf: line); return true }
            catch { return false }
        }

        guard send(["id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "usage-island", "version": "0.1"],
            "capabilities": ["experimentalApi": true]
        ]]) else { return nil }

        // Wait for actual RPC replies, keeping stdin open. A fixed two-second delay
        // closed the connection before slow startup/network responses could arrive.
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var pending = Data()
        var initialized = false
        var bytes = [UInt8](repeating: 0, count: 8192)
        var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor,
                                events: Int16(POLLIN), revents: 0)
        while ProcessInfo.processInfo.systemUptime < deadline {
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; return nil }
            if ready == 0 { continue }
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor.fd, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR { continue }; return nil }
            guard count > 0 else { return nil }
            pending.append(contentsOf: bytes.prefix(count))
            guard pending.count <= 1_048_576 else { return nil }
            while let newline = pending.firstIndex(of: 10) {
                let line = pending.subdata(in: pending.startIndex..<newline)
                pending.removeSubrange(pending.startIndex...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = (object["id"] as? NSNumber)?.intValue else { continue }
                if id == 1 && !initialized {
                    guard object["error"] == nil, object["result"] != nil,
                          send(["method": "initialized", "params": [:]]),
                          send(["id": 2, "method": "account/rateLimits/read"]) else { return nil }
                    initialized = true
                } else if id == 2 && initialized {
                    guard let result = object["result"] as? [String: Any] else { return nil }
                    return parse(result: result)
                }
            }
        }
        return nil
    }

    static func parse(result: [String: Any]) -> Reading? {
        guard let legacy = result["rateLimits"] as? [String: Any] else { return nil }
        let bucketID = legacy["limitId"] as? String
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        let rateLimits = bucketID.flatMap { buckets?[$0] as? [String: Any] } ?? legacy
        guard
              let primary = rateLimits["primary"] as? [String: Any],
              let used = UsageValidation.percent(json: primary["usedPercent"]),
              let additional = extras(de: result, principal: rateLimits, id: bucketID) else { return nil }
        if let raw = primary["resetsAt"], !(raw is NSNull), resetDate(raw) == nil { return nil }
        let resetAt = resetDate(primary["resetsAt"])
        let mainID = (bucketID ?? "codex") + "-primary"
        let duration = (primary["windowDurationMins"] as? NSNumber).map { $0.doubleValue * 60 }
        let windows = [QuotaWindow(id: mainID, title: windowLabel(primary), percent: used, resetsAt: resetAt,
                                   duration: duration, blocked: rateLimits["rateLimitReachedType"] as? String != nil)]
            + additional.map { QuotaWindow(id: $0.id, title: $0.titulo, percent: $0.percent, resetsAt: $0.resetsAt, duration: $0.duration, blocked: $0.blocked) }
        guard windows.allSatisfy(\.valid) else { return nil }
        return Reading(percentUsed: used, resetText: resetText(for: resetAt),
                       updatedAt: .now,
                       extras: additional, limitLabel: windowLabel(primary),
                       blocked: windows.contains(where: \.blocked),
                       windows: windows, primaryWindowID: mainID)
    }

    /// Le o `rateLimitsByLimitId`, pulando a entrada que ja e o limite do anel.
    ///
    /// Preserve secondary from the main bucket too, including measured zero after reset.
    private static func extras(de result: [String: Any], principal: [String: Any], id: String?) -> [Janela]? {
        var porId = result["rateLimitsByLimitId"] as? [String: Any] ?? [:]
        let mainID = id ?? "codex"
        porId[mainID] = principal
        var linhas: [Janela] = []
        for (chave, valor) in porId {
            guard let bloco = valor as? [String: Any] else { return nil }
            let nome = (bloco["limitName"] as? String) ?? chave
            for sufixo in ["primary", "secondary"] {
                if chave == mainID && sufixo == "primary" { continue }
                guard let raw = bloco[sufixo], !(raw is NSNull) else { continue }
                guard let janela = raw as? [String: Any],
                      let usado = UsageValidation.percent(json: janela["usedPercent"]) else { return nil }
                if let raw = janela["resetsAt"], !(raw is NSNull), resetDate(raw) == nil { return nil }
                let quando = resetDate(janela["resetsAt"])
                let label = windowLabel(janela)
                linhas.append(Janela(id: "\(chave)-\(sufixo)", titulo: chave == mainID ? label : "\(nome) · \(label)",
                                     percent: usado, reset: resetText(for: quando), resetsAt: quando,
                                     duration: (janela["windowDurationMins"] as? NSNumber).map { $0.doubleValue * 60 },
                                     blocked: bloco["rateLimitReachedType"] as? String != nil))
            }
        }
        return linhas.sorted { $0.percent == $1.percent ? $0.id < $1.id : $0.percent > $1.percent }
    }

    static func windowLabel(_ window: [String: Any]) -> String {
        guard let minutes = (window["windowDurationMins"] as? NSNumber)?.intValue, minutes > 0 else { return "Outra janela" }
        if minutes == 10080 { return "Semanal" }
        if minutes == 1440 { return "Diária" }
        if minutes % 60 == 0 { return "Janela de \(minutes / 60)h" }
        return "Janela de \(minutes)min"
    }

    private static func resetDate(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, (0...40_000_000_000).contains(number.doubleValue) else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue)
    }

    private static func resetText(for date: Date?) -> String {
        guard let date else { return "Reset não informado" }
        guard date > .now else { return "Reiniciando" }
        let components = Calendar.current.dateComponents([.day, .hour, .minute], from: .now, to: date)
        if let day = components.day, day > 0 { return "Reinicia em \(day)d \(max(0, components.hour ?? 0))h" }
        if let hour = components.hour, hour > 0 { return "Reinicia em \(hour)h" }
        return "Reinicia em \(max(1, components.minute ?? 1))min"
    }
}
