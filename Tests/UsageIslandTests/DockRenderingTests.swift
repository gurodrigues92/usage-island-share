import AppKit
import SwiftUI
import XCTest
@testable import UsageIsland

@MainActor
final class DockRenderingTests: XCTestCase {
    func testDockHandleHiddenHintAndCompletionRenderOnBothEdges() throws {
        let suite = "UsageIsland-DockRender-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = UsageSettings(defaults: defaults, initial: [.init(id: "Codex", source: .codex)])
        let model = IslandModel(settings: settings,
            history: UsageHistory(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            defaults: defaults, profiles: [])
        model.isPointerOverIsland = { true }
        let now = Date()
        let busy = AgentSession(id: "test", name: "Projeto de demonstração", detail: "Codex", state: .busy, waitingFor: nil, since: now)
        let done = AgentSession(id: "test", name: busy.name, detail: "Codex", state: .idle, waitingFor: nil, since: now, completionConfirmed: true)
        for edge in [IslandEdge.right, .left] {
            settings.edit { $0.edge = edge; $0.dock.autoHide = false }
            model.setHovering(true)
            try render(IslandView(model: model), name: "dock-handle-" + edge.rawValue,
                       width: model.fullMetrics.railWidth, height: model.fullMetrics.islandHeight + model.dockFooterHeight)
            settings.edit { $0.dock.autoHide = true }
            model.isPointerOverIsland = { false }
            model.setHovering(false, now: now)
            model.tickIdleWatchdog(now: now.addingTimeInterval(60))
            XCTAssertTrue(model.isDockHidden)
            try render(IslandView(model: model), name: "dock-hidden-" + edge.rawValue,
                       width: model.fullMetrics.railWidth, height: model.fullMetrics.islandHeight + model.dockFooterHeight)
            model.receiveExternalActivity([.codex: [busy]])
            model.receiveExternalActivity([.codex: [done]])
            XCTAssertTrue(model.dockNoticeVisible)
            try render(IslandView(model: model), name: "dock-completion-" + edge.rawValue,
                       width: model.fullMetrics.expandedWidth, height: model.fullMetrics.islandHeight + model.dockFooterHeight)
            model.dockActivity = DockActivityState()
        }
    }

    private func render<V: View>(_ view: V, name: String, width: CGFloat, height: CGFloat) throws {
        let host = NSHostingView(rootView: view.frame(width: width, height: height))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now.addingTimeInterval(0.4))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var visible = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.redComponent + c.greenComponent + c.blueComponent > 0.3 { visible += 1 }
            }
        }
        XCTAssertGreaterThan(visible, 10, name)
        if let output = ProcessInfo.processInfo.environment["USAGE_ISLAND_RENDER_DIR"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
        }
        window.contentView = nil
    }
}
