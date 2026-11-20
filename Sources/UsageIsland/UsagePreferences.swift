import AppKit
import Combine
import Foundation

struct RingPreference: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var source: UsageSource
    var accountSlug: String? = nil
    var name = ""
    var symbol = ""
    var visible = true
    var enabled = true
    var preferredWindow: String? = nil
    /// Nil preserves the existing global preference when older settings are decoded.
    var remainingOverride: Bool? = nil
    var directory: String? = nil
    var manualPercent: Double? = nil
    var manualUpdatedAt: Date? = nil

    var displayName: String { name.isEmpty ? accountSlug.map { "\(source.rawValue) (\($0))" } ?? source.rawValue : name }
}

enum IslandEdge: String, Codable, CaseIterable, Sendable { case right, left }
enum DockPresentation: String, Codable, CaseIterable, Sendable {
    case overlay, appWindows
    var title: String {
        switch self {
        case .overlay: "Sobre outros apps"
        case .appWindows: "Com as janelas do Usage Island"
        }
    }
}

enum DockSizeMode { case compact, hover }

struct DockPreferences: Codable, Equatable, Sendable {
    var enabled = true
    var autoHide = false
    var edgeHint = true
    var dragHandle = true
    var scale: Double = 1
    // Older installations used a single percentage for both presentations.
    private var storedHoverScale: Double? = 1
    var hoverScale: Double {
        get { storedHoverScale ?? scale }
        set { storedHoverScale = newValue }
    }
    var presentation: DockPresentation = .overlay
    var showCompleted = true
    var showNewActivity = true

    func normalized() -> Self {
        var result = self
        func clamped(_ value: Double) -> Double {
            value.isFinite ? min(1.5, max(0.5, value)) : 1
        }
        result.scale = clamped(scale)
        result.hoverScale = clamped(hoverScale)
        return result
    }
}

enum IslandTheme: String, Codable, CaseIterable, Sendable {
    case system, dark, light
    var title: String { switch self { case .system: "Sistema"; case .dark: "Escuro"; case .light: "Claro" } }
    var appearance: NSAppearance? { switch self { case .system: nil; case .dark: NSAppearance(named: .darkAqua); case .light: NSAppearance(named: .aqua) } }
}

struct ModelPrice: Codable, Equatable, Identifiable, Sendable {
    var model: String
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite: Double
    var id: String { model }
    var valid: Bool { !model.isEmpty && [input, output, cacheRead, cacheWrite].allSatisfy { $0.isFinite && (0...100_000_000).contains($0) } }
}

struct UsagePreferences: Codable, Equatable, Sendable {
    var version = 1
    var rings: [RingPreference] = []
    var remaining = false
    var alwaysShowNumbers = false
    var railWidth: Double = 92
    var compactOpacity: Double = 0.55
    var edge: IslandEdge = .right
    var screenID: String? = nil
    var verticalPosition: Double = 0.5
    var lowPower = false
    var highContrast = false
    var shortcutEnabled = false
    // Optional storage lets existing v1 settings decode without losing icons or layout.
    private var storedDock: DockPreferences? = nil
    var dock: DockPreferences {
        get { storedDock ?? DockPreferences() }
        set { storedDock = newValue }
    }
    private var storedAnimationSpeed: Double? = nil
    private var storedTheme: IslandTheme? = nil
    var theme: IslandTheme { get { storedTheme ?? .dark } set { storedTheme = newValue } }
    private var storedCollapseDelay: Double? = nil
    private var storedCardCollapseDelay: Double? = nil
    var animationSpeed: Double {
        get { storedAnimationSpeed ?? 1 }
        set { storedAnimationSpeed = newValue }
    }
    var collapseDelay: TimeInterval {
        get { storedCollapseDelay ?? 0.65 }
        set { storedCollapseDelay = newValue }
    }
    var cardCollapseDelay: TimeInterval {
        get { storedCardCollapseDelay ?? 15 }
        set { storedCardCollapseDelay = newValue }
    }
    var hoverAnimationDuration: TimeInterval { 0.28 / animationSpeed }
    var cardAnimationDuration: TimeInterval { 0.32 / animationSpeed }
    var panelShrinkDelay: TimeInterval { cardAnimationDuration + 0.12 }
    var forecast = true
    var retentionDays = 90
    var notifications = false
    var thresholds: [Int] = [80, 90, 100]
    var notifyRecovery = true
    var notifyForecast = false
    var notifySessions = false
    var quietHours = false
    var quietFrom = 22
    var quietUntil = 8
    var checkServiceStatus = true
    // Standard API prices checked on 2026-10-14; other models stay unpriced.
    var prices: [ModelPrice] = [
        .init(model: "claude-opus-4-6", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        .init(model: "claude-sonnet-4-6", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        .init(model: "claude-sonnet-4-5", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        .init(model: "claude-haiku-4-5", input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25)
    ]

    func normalized() -> Self {
        var result = self
        var ids = Set<String>()
        result.rings = rings.filter { !$0.id.isEmpty && ids.insert($0.id).inserted }.prefix(24).map { item in
            var item = item
            item.name = String(item.name.prefix(48))
            item.symbol = String(item.symbol.prefix(80))
            item.manualPercent = UsageValidation.percent(item.manualPercent)
            return item
        }
        result.railWidth = railWidth.isFinite ? min(130, max(72, railWidth)) : 92
        result.compactOpacity = compactOpacity.isFinite ? min(1, max(0.25, compactOpacity)) : 0.55
        result.verticalPosition = verticalPosition.isFinite ? min(1, max(0, verticalPosition)) : 0.5
        result.dock = dock.normalized()
        result.animationSpeed = animationSpeed.isFinite ? min(3, max(0.25, animationSpeed)) : 1
        result.collapseDelay = collapseDelay.isFinite ? min(15, max(0, collapseDelay)) : 0.65
        result.cardCollapseDelay = cardCollapseDelay.isFinite ? min(60, max(0, cardCollapseDelay)) : 15
        result.retentionDays = [7, 30, 90, 365].contains(retentionDays) ? retentionDays : 90
        result.thresholds = Array(Set(thresholds.filter { (1...100).contains($0) })).sorted()
        result.quietFrom = min(23, max(0, quietFrom)); result.quietUntil = min(23, max(0, quietUntil))
        var models = Set<String>()
        result.prices = prices.filter { $0.valid && models.insert($0.model).inserted }
        return result
    }

    func isQuiet(at now: Date, calendar: Calendar = .current) -> Bool {
        guard quietHours, quietFrom != quietUntil else { return false }
        let hour = calendar.component(.hour, from: now)
        return quietFrom < quietUntil ? (quietFrom..<quietUntil).contains(hour) : hour >= quietFrom || hour < quietUntil
    }

    func showsRemaining(for entryID: String) -> Bool {
        rings.first { $0.id == entryID }?.remainingOverride ?? remaining
    }
}

@MainActor
final class UsageSettings: ObservableObject {
    static let storageKey = "usageIsland.preferences.v1"
    @Published private(set) var value: UsagePreferences
    @Published private(set) var issue: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, initial: [RingPreference] = []) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey) {
            if let saved = try? JSONDecoder().decode(UsagePreferences.self, from: data), saved.version == 1 {
                value = saved.normalized()
            } else {
                var fallback = UsagePreferences(); fallback.rings = initial
                value = fallback
                issue = "Não foi possível abrir as configurações salvas. O arquivo anterior foi preservado."
                defaults.set(data, forKey: Self.storageKey + ".unreadable")
            }
        } else { var fresh = UsagePreferences(); fresh.rings = initial; value = fresh }
    }

    func edit(_ change: (inout UsagePreferences) -> Void) {
        var updated = value; change(&updated); updated = updated.normalized()
        guard updated != value else { return }
        value = updated
        if let data = try? JSONEncoder().encode(updated) { defaults.set(data, forKey: Self.storageKey) }
    }
    func editRing(_ id: String, _ change: (inout RingPreference) -> Void) {
        edit { prefs in
            if let index = prefs.rings.firstIndex(where: { $0.id == id }) {
                let oldPercent = prefs.rings[index].manualPercent
                change(&prefs.rings[index])
                if oldPercent != prefs.rings[index].manualPercent { prefs.rings[index].manualUpdatedAt = .now }
            }
        }
    }
    func move(_ id: String, by offset: Int) {
        edit { prefs in
            guard let from = prefs.rings.firstIndex(where: { $0.id == id }) else { return }
            let to = min(prefs.rings.count - 1, max(0, from + offset))
            if from != to { prefs.rings.insert(prefs.rings.remove(at: from), at: to) }
        }
    }
    func move(_ id: String, before destination: String) {
        edit { prefs in
            guard id != destination, let from = prefs.rings.firstIndex(where: { $0.id == id }),
                  prefs.rings.contains(where: { $0.id == destination }) else { return }
            let item = prefs.rings.remove(at: from)
            if let to = prefs.rings.firstIndex(where: { $0.id == destination }) { prefs.rings.insert(item, at: to) }
        }
    }
    func add(_ ring: RingPreference) { edit { if !$0.rings.contains(where: { $0.id == ring.id }) { $0.rings.append(ring) } } }
    func remove(_ id: String) { edit { $0.rings.removeAll { $0.id == id } } }

    static func defaults(profiles: [ClaudeProfile]) -> [RingPreference] {
        profiles.map { .init(id: ClaudeProfile.ringID(slug: $0.slug), source: .claude, accountSlug: $0.slug) }
            + [.init(id: "Codex", source: .codex), .init(id: "SuperGrok", source: .grok), .init(id: "OpenCode", source: .opencode)]
    }
}

enum IslandScreen {
    static func id(_ screen: NSScreen) -> String? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
    }
    @MainActor static func choose(_ id: String?) -> NSScreen? {
        id.flatMap { chosen in NSScreen.screens.first { Self.id($0) == chosen } } ?? NSScreen.main ?? NSScreen.screens.first
    }
}
