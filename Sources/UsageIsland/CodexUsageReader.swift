import Foundation

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
    }

    struct Janela: Sendable {
        let id: String
        let titulo: String
        let percent: Double
        let reset: String
    }

    static func read() async -> Reading? {
        await Task.detached(priority: .utility) { readSynchronously() }.value
    }

    private static func readSynchronously() -> Reading? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()

        do { try process.run() } catch { return nil }

        func send(_ object: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: object),
                  let line = String(data: data, encoding: .utf8)?.appending("\n").data(using: .utf8) else { return }
            try? input.fileHandleForWriting.write(contentsOf: line)
        }

        send(["id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "usage-island", "version": "0.1"],
            "capabilities": ["experimentalApi": true]
        ]])
        Thread.sleep(forTimeInterval: 0.5)
        send(["id": 2, "method": "account/rateLimits/read"])
        // The local app-server resolves account state asynchronously on startup.
        // Keep stdin alive long enough for the read response to be emitted.
        Thread.sleep(forTimeInterval: 1.5)
        try? input.fileHandleForWriting.close()

        // Watchdog. `readDataToEndOfFile()` only returns on EOF, and EOF only comes when the
        // helper exits. A helper that hangs — the usual cause is a PATH that does not reach
        // the CLI's own dependencies — used to block this thread forever. Since the app now
        // ignores SIGPIPE it no longer dies from it, so the hang became silent: the island
        // simply stopped updating. Killing the process forces EOF, and a non-zero status
        // below turns the whole reading into `nil`, which keeps the previous number.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  (object["id"] as? NSNumber)?.intValue == 2,
                  let result = object["result"] as? [String: Any],
                  let rateLimits = result["rateLimits"] as? [String: Any],
                  let primary = rateLimits["primary"] as? [String: Any],
                  let used = primary["usedPercent"] as? NSNumber else { continue }
            let resetAt = (primary["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return Reading(percentUsed: used.doubleValue, resetText: resetText(for: resetAt),
                           updatedAt: .now,
                           extras: extras(de: result, exceto: rateLimits["limitId"] as? String))
        }
        return nil
    }

    /// Le o `rateLimitsByLimitId`, pulando a entrada que ja e o limite do anel.
    ///
    /// Uma janela zerada e omitida de proposito: um modelo que nao se usou nao diz nada e so
    /// alongaria o card. Cada entrada rende ate duas linhas — a curta e a semanal.
    private static func extras(de result: [String: Any], exceto principal: String?) -> [Janela] {
        guard let porId = result["rateLimitsByLimitId"] as? [String: Any] else { return [] }
        var linhas: [Janela] = []
        for (chave, valor) in porId {
            guard chave != principal, let bloco = valor as? [String: Any] else { continue }
            let nome = (bloco["limitName"] as? String) ?? chave
            for (sufixo, rotulo) in [("primary", ""), ("secondary", " semanal")] {
                guard let janela = bloco[sufixo] as? [String: Any],
                      let usado = (janela["usedPercent"] as? NSNumber)?.doubleValue,
                      usado > 0 else { continue }
                let quando = (janela["resetsAt"] as? NSNumber)
                    .map { Date(timeIntervalSince1970: $0.doubleValue) }
                linhas.append(Janela(id: "\(chave)-\(sufixo)", titulo: nome + rotulo,
                                     percent: usado, reset: resetText(for: quando)))
            }
        }
        return linhas.sorted { $0.percent > $1.percent }
    }

    private static func resetText(for date: Date?) -> String {
        guard let date else { return "Reset não informado" }
        let components = Calendar.current.dateComponents([.day, .hour], from: .now, to: date)
        if let day = components.day, day > 0 { return "Reinicia em \(day)d \(max(0, components.hour ?? 0))h" }
        return "Reinicia em \(max(0, components.hour ?? 0))h"
    }
}
