import Foundation
import UserNotifications

struct UsageAlert: Equatable, Sendable {
    enum Kind: String, Codable { case threshold, recovered, forecast, session }
    var id: String
    var kind: Kind
    var title: String
    var body: String
}

struct QuotaAlertState: Codable, Equatable {
    var reset: Date?
    var lastPercent: Double
    var lastReading: Date
    var blocked: Bool
    var fired: Set<Int> = []
    var forecastFired = false
}

@MainActor
final class QuotaAlerts {
    private(set) var states: [String: QuotaAlertState]
    private let defaults: UserDefaults
    private static let key = "usageIsland.alertState.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        states = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: QuotaAlertState].self, from: $0) } ?? [:]
    }

    func review(_ snapshot: UsageSnapshot, preferences: UsagePreferences, forecasts: [String: QuotaForecast] = [:], now: Date = .now) -> [UsageAlert] {
        guard snapshot.syncState == .live, snapshot.fidelity == .oficial, !snapshot.isStale(now: now) else { return [] }
        var events: [UsageAlert] = []
        for window in snapshot.windows where window.valid {
            guard window.resetsAt == nil || window.resetsAt! > snapshot.updatedAt else { continue }
            let key = snapshot.id + "|" + window.id
            let old = states[key]
            guard old == nil || snapshot.updatedAt > old!.lastReading else { continue }
            let blocked = window.blocked || window.percent == 100
            let newCycle = old != nil && (old!.reset != window.resetsAt || old!.lastPercent - window.percent >= 2)
            var state = old ?? .init(reset: window.resetsAt, lastPercent: window.percent, lastReading: snapshot.updatedAt, blocked: blocked)
            if newCycle { state.fired = []; state.forecastFired = false }
            let resetID = window.resetsAt.map { String(Int64($0.timeIntervalSince1970)) } ?? "unknown"
            if let old {
                for threshold in preferences.thresholds where window.percent >= Double(threshold) && old.lastPercent < Double(threshold) {
                    if state.fired.insert(threshold).inserted {
                        events.append(.init(id: key + "|\(resetID)|\(threshold)", kind: .threshold,
                            title: "\(snapshot.displayName): \(threshold == 100 ? "limite atingido" : "cota em \(Int(window.percent))%")",
                            body: "\(window.title) · \(window.resetText(now: now))"))
                    }
                }
                if blocked && !old.blocked && window.percent < 100 {
                    events.append(.init(id: key + "|\(resetID)|blocked", kind: .threshold,
                        title: "\(snapshot.displayName): janela bloqueada", body: "\(window.title) · \(window.resetText(now: now))"))
                }
                if old.blocked && !blocked && preferences.notifyRecovery {
                    events.append(.init(id: key + "|\(resetID)|recovered", kind: .recovered,
                        title: "\(snapshot.displayName): cota disponível novamente", body: "\(window.title) · \(Int(window.percent))% usado na nova leitura"))
                }
            }
            if let forecast = forecasts[window.id], forecast.confidence != .low {
                if forecast.atRisk, preferences.notifyForecast, !state.forecastFired {
                    state.forecastFired = true
                    events.append(.init(id: key + "|\(resetID)|forecast", kind: .forecast,
                        title: "\(snapshot.displayName): pode acabar antes do reset",
                        body: "\(window.title) · previsão pelo consumo recente · confiança \(forecast.confidence.rawValue.lowercased())"))
                } else if !forecast.atRisk { state.forecastFired = false }
            }
            state.reset = window.resetsAt; state.lastPercent = window.percent
            state.lastReading = snapshot.updatedAt; state.blocked = blocked
            states[key] = state
        }
        if states.count > 512 { states = states.filter { now.timeIntervalSince($0.value.lastReading) < 30 * 86400 } }
        if let data = try? JSONEncoder().encode(states) { defaults.set(data, forKey: Self.key) }
        return preferences.notifications && !preferences.isQuiet(at: now) ? events : []
    }
}

@MainActor
final class UsageNotifications {
    private lazy var center = UNUserNotificationCenter.current()
    private(set) var issue: String?
    func authorize() async -> Bool {
        do {
            let allowed = try await center.requestAuthorization(options: [.alert, .sound])
            issue = allowed ? nil : "Notificações não autorizadas. Ajuste em Configurações do Sistema → Notificações."
            return allowed
        } catch { issue = "Não foi possível ativar notificações nesta instalação."; return false }
    }
    func send(_ alerts: [UsageAlert]) async {
        for alert in alerts {
            let content = UNMutableNotificationContent(); content.title = alert.title; content.body = alert.body
            content.sound = .default
            do { try await center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)) }
            catch { issue = "Falha ao entregar uma notificação do Usage Island." }
        }
    }
}
