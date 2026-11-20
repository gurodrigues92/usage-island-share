import AppKit
import SwiftUI
import XCTest
@testable import UsageIsland

@MainActor
final class CardRenderingTests: XCTestCase {
    func testCardsRenderWithinViewport() throws {
        let output = ProcessInfo.processInfo.environment["USAGE_ISLAND_RENDER_DIR"]
        var healthy = UsageSnapshot(source: .codex, percentUsed: 20, sessionPercent: nil,
            resetText: "Reinicia em 2h", updatedAt: .now, syncState: .live)
        healthy.limitLabel = "Janela de 5h"
        healthy.fidelity = .oficial
        var stale = healthy
        stale.updatedAt = .now.addingTimeInterval(-3600)
        stale.markFailed("Sem conexão · nova tentativa automática")
        var large = healthy
        large.extraWindows = (1...9).map { .init(id: "model-\($0)", title: "Modelo \($0) semanal", percent: Double($0 * 10), reset: "Reinicia em 2d") }
        var expired = UsageSnapshot(source: .opencode, percentUsed: 6, sessionPercent: nil,
                                    resetText: "", updatedAt: .now.addingTimeInterval(-3 * 86400), syncState: .live)
        expired.applyOpenCodeResult(.failure(.expiredKey))
        var noReading = UsageSnapshot(source: .opencode, percentUsed: nil, sessionPercent: nil, resetText: "", updatedAt: .now, syncState: .loading)
        noReading.applyOpenCodeResult(.failure(.expiredKey))
        for (name, snapshot) in [("leitura-atual", healthy), ("leitura-antiga", stale), ("muitas-janelas", large), ("opencode-chave-expirada", expired), ("opencode-sem-leitura", noReading)] {
            let height = IslandLayout.cardHeight(rows: snapshot.cardRows, splitLine: false, availableHeight: 514)
            // ScrollView uses native AppKit views, which ImageRenderer omits. Render
            // the actual hosting view in a hidden window; never put it on screen.
            let host = NSHostingView(rootView: DetailBubble(snapshot: snapshot, arrowY: 60, initiallyPresented: true)
                .frame(width: 332, height: height))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 332, height: height),
                                  styleMask: [], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: .now.addingTimeInterval(0.15))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertEqual(host.bounds.height, height, accuracy: 1)
            var visiblePixels = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.redComponent + color.greenComponent + color.blueComponent > 0.3 {
                        visiblePixels += 1
                    }
                }
            }
            XCTAssertGreaterThan(visiblePixels, 10, "Card content must render, not only its background")
            if let output {
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
            }
            if name == "muitas-janelas" {
                let scroll = try XCTUnwrap(findScrollView(in: host))
                let document = try XCTUnwrap(scroll.documentView)
                XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height)
                let bottom = document.isFlipped ? document.frame.height - scroll.contentView.bounds.height : 0
                scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
                scroll.reflectScrolledClipView(scroll.contentView)
                RunLoop.main.run(until: .now.addingTimeInterval(0.2))
                if let output {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: output).appendingPathComponent("muitas-janelas-final.png"))
                }
            }
            window.contentView = nil
        }
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let scroll = findScrollView(in: child) { return scroll }
        }
        return nil
    }
}
