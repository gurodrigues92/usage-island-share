import Foundation
import LocalAuthentication
import Security

enum IslandSecrets {
    static let service = "org.usageisland.app.openrouter"
    static func save(_ value: String, account: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        let data = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var new = query; new[kSecValueData] = data; new[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            guard SecItemAdd(new as CFDictionary, nil) == errSecSuccess else { throw CocoaError(.fileWriteNoPermission) }
        } else if status != errSecSuccess { throw CocoaError(.fileWriteNoPermission) }
    }
    static func read(account: String) -> String? {
        var output: CFTypeRef?
        let context = LAContext(); context.interactionNotAllowed = true
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: context] as CFDictionary, &output)
        guard status == errSecSuccess, let data = output as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum OpenRouterUsageReader {
    struct Reading: Sendable { var window: QuotaWindow?; var balance: String }
    static func read(account: String) async -> Reading? {
        let key = await Task.detached(priority: .utility) { IslandSecrets.read(account: account) }.value
        guard let key, !key.isEmpty else { return nil }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization"); request.timeoutInterval = 15
        guard let (data, response) = try? await ProviderHTTP.data(for: request, key: account),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }
    static func parse(_ data: Data) -> Reading? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = root["data"] as? [String: Any] else { return nil }
        func amount(_ value: Any?) -> Double? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue >= 0 else { return nil }
            return n.doubleValue
        }
        let budget = value["effective_budget"] as? [String: Any]
        guard let spend = amount(budget?["spend_usd"] ?? value["usage"]) else { return nil }
        let text = "Uso de API: US$ " + String(format: "%.2f", spend)
        guard let limit = amount(budget?["limit_usd"] ?? value["limit"]), limit > 0 else {
            return .init(window: nil, balance: text + " · sem teto percentual informado")
        }
        let ratio = spend / limit * 100
        guard ratio.isFinite else { return nil }
        let reset = (budget?["resets_at"] as? String).flatMap { UsageDates.parse($0) }
        let interval = (budget?["reset_interval"] ?? value["limit_reset"]) as? String
        let duration: TimeInterval? = interval == "weekly" ? 7 * 86400 : interval == "daily" ? 86400 : nil
        return .init(window: .init(id: "api-budget", title: "Orçamento de API", percent: min(100, ratio),
                                  resetsAt: reset, duration: duration, blocked: ratio >= 100),
                     balance: text + " de US$ " + String(format: "%.2f", limit))
    }
}

enum UsageDates {
    static func parse(_ value: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
