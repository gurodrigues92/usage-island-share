import Foundation
import os
import Security
import SQLite3
import CommonCrypto

/// Reads the shared weekly SuperGrok quota through the same authenticated billing route
/// used by Grok Build's /usage command. Balance availability is not a usage percentage.
struct GrokUsageReader {
    struct WebLimits: Sendable, Equatable {
        let percentUsed: Double
        let remaining: Int
        let total: Int
        let windowSeconds: Int

        var windowLabel: String {
            let hours = windowSeconds / 3600
            return hours > 0 ? "Chat web · \(hours)h" : "Chat web"
        }
    }

    struct Reading: Sendable {
        let weekly: GrokWeeklyUsage?
        let web: WebLimits?
        let updatedAt: Date
    }

    /// Optional and disabled by default. Reading Arc cookies requires Keychain
    /// authorization; the weekly quota does not depend on this feature.
    static let webBarKey = "usageIsland.grokWebBar"
    static var isWebBarEnabled: Bool { UserDefaults.standard.bool(forKey: webBarKey) }

    /// One keychain read per launch. The cookie changes only when the user signs in again,
    /// and asking every poll is what turned one dialog into a recurring one.
    private static let cachedCookie = OSAllocatedUnfairLock<String??>(initialState: nil)

    static func read() async -> Reading {
        let weekly = await readWeeklyUsage()
        let web = isWebBarEnabled ? await readWebLimits() : nil
        return Reading(weekly: weekly, web: web, updatedAt: .now)
    }

    // MARK: - Shared weekly allowance

    private static func readWeeklyUsage() async -> GrokWeeklyUsage? {
        if isTokenExpired() { await renewTokenWithCLI() }
        guard let token = cliToken() else { return nil }
        var request = URLRequest(url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(cliVersion(), forHTTPHeaderField: "x-grok-client-version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let usage = GrokWeeklyUsage.parse(data) else { return nil }
        return usage
    }

    /// The CLI keeps a fresh access token on disk and rotates it itself; we only read it.
    private static func cliToken() -> String? { authEntry()?["key"] as? String }

    /// Checks the expiry timestamp stored by the CLI before requesting usage.
    private static func isTokenExpired() -> Bool {
        guard let entry = authEntry(), let raw = entry["expires_at"] as? String else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let expires = formatter.date(from: raw) else { return false }
        // Dois minutos de folga: token que vence no meio da requisicao volta como 401.
        return expires.timeIntervalSinceNow < 120
    }

    /// Renovar pela propria CLI, nao na mao. O `auth.json` guarda um `refresh_token`, mas
    /// gasta-lo aqui rotacionaria a credencial por baixo da CLI e poderia interromper a sessão da CLI.
    /// `grok models` faz a rotacao sancionada e reescreve o arquivo — e note que ele imprime
    /// "You are not authenticated" mesmo quando renova com sucesso, entao a saida dele nao
    /// serve de sinal: o que vale e o `expires_at` novo no arquivo.
    ///
    /// O binario mora em `~/.grok/bin/grok`, que **nao esta no PATH** entregue pelo launchd —
    /// por isso o caminho absoluto vem primeiro na lista.
    private static func renewTokenWithCLI() async {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.grok/bin/grok", "\(home)/.local/bin/grok",
                          "/opt/homebrew/bin/grok", "/usr/local/bin/grok"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return }

        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["models"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 25, execute: watchdog)
            process.waitUntilExit()
            watchdog.cancel()
        }.value
        IslandLog.write(isTokenExpired()
                        ? "Grok: a CLI não renovou o token; uso indisponível"
                        : "Grok: credencial revalidada pela CLI")
    }

    private static func authEntry() -> [String: Any]? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json").path
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for value in root.values {
            if let entry = value as? [String: Any], (entry["key"] as? String)?.isEmpty == false { return entry }
        }
        return nil
    }

    private static func cliVersion() -> String {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/version.json").path
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["version"] as? String, !version.isEmpty else { return "1.0.13" }
        return version
    }

    // MARK: - Web chat rate limit

    private static func readWebLimits() async -> WebLimits? {
        guard let cookie = cookieHeaderOncePerLaunch() else { return nil }
        var request = URLRequest(url: URL(string: "https://grok.com/rest/rate-limits")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/", forHTTPHeaderField: "Referer")
        request.httpBody = #"{"requestKind":"DEFAULT","modelName":"grok-4"}"#.data(using: .utf8)
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let total = (root["totalQueries"] as? NSNumber)?.intValue, total > 0,
              let remaining = (root["remainingQueries"] as? NSNumber)?.intValue else { return nil }
        let window = (root["windowSizeSeconds"] as? NSNumber)?.intValue ?? 0
        let used = Double(max(0, total - remaining)) / Double(total) * 100
        return WebLimits(percentUsed: used, remaining: remaining, total: total, windowSeconds: window)
    }

    private static func cookieHeaderOncePerLaunch() -> String? {
        cachedCookie.withLock { slot in
            if let resolved = slot { return resolved }
            let header = grokCookieHeader()
            slot = .some(header)
            return header
        }
    }

    /// Arc stores cookies in a Chromium database, values encrypted with a key kept in the
    /// login keychain. Reading that key prompts the user once per signed build of this app —
    /// declining simply means the card loses the web line, never that the ring goes wrong.
    private static func grokCookieHeader() -> String? {
        guard let key = cookieEncryptionKey() else { return nil }
        let db = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arc/User Data/Default/Cookies").path
        guard FileManager.default.fileExists(atPath: db) else { return nil }

        var handle: OpaquePointer?
        // Opened read-only and immutable: Arc keeps the database open, and a normal read would
        // otherwise contend for its lock.
        guard sqlite3_open_v2("file:\(db)?immutable=1", &handle,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        let sql = "select name, encrypted_value from cookies where host_key like '%grok.com'"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        var jar: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let namePointer = sqlite3_column_text(statement, 0) else { continue }
            let name = String(cString: namePointer)
            guard let blob = sqlite3_column_blob(statement, 1) else { continue }
            let length = Int(sqlite3_column_bytes(statement, 1))
            let encrypted = Data(bytes: blob, count: length)
            if let value = decryptCookie(encrypted, key: key), !value.isEmpty { jar[name] = value }
        }
        // `sso` is the session; without it the rest is worthless.
        guard jar["sso"] != nil else { return nil }
        return jar.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    private static func cookieEncryptionKey() -> Data? {
        for service in ["Arc Safe Storage", "Arc", "Chromium Safe Storage"] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let password = item as? Data, !password.isEmpty else { continue }
            return derive(password: password)
        }
        return nil
    }

    /// Chromium's fixed recipe on macOS: PBKDF2-SHA1, salt "saltysalt", 1003 rounds, 16 bytes.
    private static func derive(password: Data) -> Data? {
        let salt = Array("saltysalt".utf8)
        var derived = [UInt8](repeating: 0, count: 16)
        let status = password.withUnsafeBytes { raw -> Int32 in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 raw.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                 salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                 &derived, derived.count)
        }
        return status == kCCSuccess ? Data(derived) : nil
    }

    private static func decryptCookie(_ blob: Data, key: Data) -> String? {
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else {
            return String(data: blob, encoding: .utf8)
        }
        let body = blob.dropFirst(3)
        guard body.count % kCCBlockSizeAES128 == 0 else { return nil }

        var output = [UInt8](repeating: 0, count: body.count + kCCBlockSizeAES128)
        var moved = 0
        // IV is sixteen spaces, and padding is stripped by hand because Chromium's blob is
        // block-aligned PKCS#7 that CCCrypt's own option rejects on some values.
        let iv = [UInt8](repeating: 0x20, count: 16)
        let status = body.withUnsafeBytes { input -> CCCryptorStatus in
            key.withUnsafeBytes { keyBytes in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                        keyBytes.baseAddress, key.count, iv,
                        input.baseAddress, body.count,
                        &output, output.count, &moved)
            }
        }
        guard status == kCCSuccess, moved > 0 else { return nil }
        var bytes = Array(output[0..<moved])
        if let pad = bytes.last, pad >= 1, pad <= 16, bytes.count >= Int(pad) {
            bytes.removeLast(Int(pad))
        }
        if let text = String(bytes: bytes, encoding: .utf8) { return text }
        // Chrome 130+ prefixes the plaintext with a 32-byte hash of the domain.
        guard bytes.count > 32 else { return nil }
        return String(bytes: bytes.dropFirst(32), encoding: .utf8)
    }
}
