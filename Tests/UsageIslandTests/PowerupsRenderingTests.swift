import AppKit
import SwiftUI
import XCTest
@testable import UsageIsland

@MainActor
final class PowerupsRenderingTests: XCTestCase {
    func testSettingsDashboardAndEmptyBarRender() throws {
        let suite = "UsageIsland-Rendering-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let historyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = UsageSettings(defaults: defaults, initial: UsageSettings.defaults(profiles: [.padrao]))
        let history = UsageHistory(url: historyURL)
        let model = IslandModel(settings: settings, history: history, defaults: defaults, profiles: [.padrao])
        let now = Date()
        for index in model.allSnapshots.indices {
            model.allSnapshots[index].percentUsed = Double(20 + index * 10)
            model.allSnapshots[index].updatedAt = now
            model.allSnapshots[index].syncState = .live
            model.allSnapshots[index].fidelity = .oficial
            model.allSnapshots[index].windows = [.init(id: "weekly", title: "Semanal", percent: Double(20 + index * 10), resetsAt: now.addingTimeInterval(3 * 86400), duration: 7 * 86400)]
        }
        for minute in [40, 30, 20, 10, 0] {
            var snapshot = model.allSnapshots[1]
            snapshot.updatedAt = now.addingTimeInterval(-Double(minute) * 60)
            snapshot.windows[0].percent = Double(60 - minute)
            history.record(snapshot, retentionDays: 90, now: snapshot.updatedAt)
        }
        try render(SettingsView(model: model), name: "configuracoes-barra", width: 820, height: 700)
        try render(AppearanceSettings(model: model, settings: settings), name: "configuracoes-aparencia", width: 790, height: 590)
        try render(AlertSettings(model: model, settings: settings), name: "configuracoes-alertas", width: 790, height: 590)
        try render(DashboardView(model: model), name: "painel-agora", width: 900, height: 730)
        try render(QuotaHistoryView(model: model, history: history), name: "historico", width: 840, height: 550)
        let ledger = SubscriptionLedger(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("subscriptions.json"))
        let plan = SubscriptionTerm(provider: "Claude", name: "Plano de demonstração", account: "Conta de teste", cents: 2000, start: UsageDay.calendar.startOfDay(for: now.addingTimeInterval(-20 * 86400)))
        try ledger.add(plan)
        try ledger.addPayment(.init(termID: plan.id, date: UsageDay.calendar.startOfDay(for: now), cents: 2000))
        let analytics = UsageAnalytics(importURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("imports.json"), defaults: defaults)
        let row = TokenUsageRow(id: "demo", provider: "Claude", project: "Loja de demonstração", model: "claude-sonnet-4-5", day: UsageDay.string(now), input: 2_000_000, output: 100_000, cacheRead: 1_000_000, cacheWrite: 0, cacheWrite1h: 0, calls: 12)
        let package = PortableUsage(machineID: UUID().uuidString, machineName: "Mac de teste", capturedAt: now, firstDay: row.day, lastDay: row.day, rows: [row])
        try analytics.importData(JSONEncoder().encode(package))
        try render(EconomicsView(analytics: analytics, ledger: ledger, settings: settings), name: "recibo", width: 900, height: 730)
        try render(SubscriptionsView(ledger: ledger), name: "assinaturas", width: 900, height: 730)
        try render(ProjectModelsView(project: row.project, rows: [row], prices: settings.value.prices), name: "projeto-modelos", width: 650, height: 500)
        try render(LocalHistoryView(library: model.localHistory), name: "conversas-inicio", width: 900, height: 650)
        model.setHovering(true)
        try render(IslandView(model: model), name: "barra-engrenagem", width: model.fullMetrics.railWidth, height: model.fullMetrics.islandHeight + model.dockFooterHeight)
        model.setHovering(false)
        model.tickIdleWatchdog(now: .now.addingTimeInterval(1))
        settings.edit { $0.rings = [] }
        try render(IslandView(model: model), name: "barra-vazia", width: 92, height: 200)
        settings.add(.init(id: "manual", source: .custom, name: "Minha IA", symbol: "brain", manualPercent: 42, manualUpdatedAt: now))
        settings.edit { $0.edge = .left; $0.alwaysShowNumbers = true }
        model.select("manual")
        try render(IslandView(model: model), name: "barra-personalizada-esquerda", width: 442, height: 240)
    }

    private func render<V: View>(_ view: V, name: String, width: CGFloat, height: CGFloat) throws {
        FileHandle.standardError.write(Data("Rendering Usage Island: \(name)\n".utf8))
        let host = NSHostingView(rootView: view.frame(width: width, height: height))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now.addingTimeInterval(0.35))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var visible = 0
        // The empty compact bar has only a small plus mark; coarse 8px samples can miss it.
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.redComponent + color.greenComponent + color.blueComponent > 0.3 { visible += 1 }
            }
        }
        XCTAssertGreaterThan(visible, name == "barra-vazia" ? 2 : 10, name + " must contain rendered content")
        if let output = ProcessInfo.processInfo.environment["USAGE_ISLAND_RENDER_DIR"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
        }
        window.contentView = nil
    }
}
