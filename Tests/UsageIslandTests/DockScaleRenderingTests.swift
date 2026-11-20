import AppKit
import SwiftUI
import XCTest
@testable import UsageIsland

@MainActor
final class DockScaleRenderingTests: XCTestCase {
    func testHoverZoomScalesRenderedCardRingSettingsAndDragHandleTogether() throws {
        let suite = "UsageIsland-DockScale-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let sources: [UsageSource] = [.claude, .codex, .grok, .opencode]
        let settings = UsageSettings(defaults: defaults, initial: sources.map {
            RingPreference(id: $0.rawValue, source: $0)
        })
        settings.edit { $0.railWidth = 72; $0.forecast = false; $0.dock.hoverScale = 1 }
        let model = IslandModel(settings: settings, history: UsageHistory(
            url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            defaults: defaults, profiles: [])
        let now = Date()
        model.allSnapshots = sources.enumerated().map { index, source in
            UsageSnapshot(source: source, percentUsed: Double(index + 1) * 20, sessionPercent: nil,
                          resetText: "Reinicia em 2h", updatedAt: now, syncState: .live)
        }
        model.select(UsageSource.codex.rawValue)
        model.previewDockSize = .hover
        defer {
            model.previewDockSize = nil
            model.isPointerOverIsland = { false }
            model.tickIdleWatchdog(now: now)
            model.tickIdleWatchdog(now: now.addingTimeInterval(120))
        }

        let size = model.dockPanelSize(expanded: true)
        let metrics = model.fullMetrics
        let full = try render(model, name: "hover-100")
        settings.edit { $0.dock.hoverScale = 0.8 }
        let small = try render(model, name: "hover-80")
        XCTAssertEqual(small.width, Int((Double(full.width) * 0.8).rounded()), accuracy: 2)
        XCTAssertEqual(small.height, Int((Double(full.height) * 0.8).rounded()), accuracy: 2)

        // Measure rendered ink inside each region, not the frame reserved for it.
        // Regions are in the unscaled view's top-left coordinates. The flat blue
        // background keeps white logos and the black native handle distinguishable.
        let railX = size.width - metrics.railWidth
        let ringY = metrics.ringCenterY(1)
        let gearY = metrics.islandHeight - metrics.flareHeight - 18
        let regions: [(String, CGRect, Bool)] = [
            ("card content", CGRect(x: 8, y: 0, width: IslandLayout.bubbleWidth - 16,
                                    height: metrics.islandHeight), true),
            ("Codex mark", CGRect(x: railX + 8, y: ringY - metrics.markSize * 0.65,
                                  width: metrics.railWidth - 16, height: metrics.markSize * 1.3), true),
            ("settings glyph", CGRect(x: railX + 5, y: gearY - 15,
                                      width: metrics.railWidth - 10, height: 30), true),
            ("drag handle", CGRect(x: railX, y: metrics.islandHeight + 1,
                                   width: metrics.railWidth, height: metrics.dragHandleFooterHeight - 1), false)
        ]
        for (name, region, white) in regions {
            let fullScale = CGFloat(full.width) / size.width
            let smallScale = CGFloat(small.width) / size.width
            let base = try inkBounds(image: full, region: region, scale: fullScale, white: white, name: name)
            let scaled = try inkBounds(image: small, region: region, scale: smallScale, white: white, name: name)
            // One-point variations at each antialiased edge are expected when font
            // hinting or subpixel rounding changes across the two physical viewports.
            XCTAssertEqual(scaled.width, base.width * 0.8, accuracy: 2 * fullScale, name + " width")
            XCTAssertEqual(scaled.height, base.height * 0.8, accuracy: 2 * fullScale, name + " height")
        }
    }

    private func render(_ model: IslandModel, name: String) throws -> CGImage {
        let size = model.dockPanelSize(expanded: true)
        let host = NSHostingView(rootView: IslandView(model: model)
            .frame(width: size.width, height: size.height)
            .background(Color(red: 0.25, green: 0.40, blue: 0.64)))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now.addingTimeInterval(1.1))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let output = ProcessInfo.processInfo.environment["USAGE_ISLAND_RENDER_DIR"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
        }
        return try XCTUnwrap(bitmap.cgImage)
    }

    private func inkBounds(image: CGImage, region: CGRect, scale: CGFloat, white: Bool,
                           name: String) throws -> CGRect {
        let rect = region.applying(CGAffineTransform(scaleX: scale, y: scale)).integral
        let crop = try XCTUnwrap(image.cropping(to: rect), name)
        let bitmap = NSBitmapImageRep(cgImage: crop)
        var bounds = CGRect.null
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                // Fractional zoom can leave transparent pixels on the bitmap boundary.
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent >= 0.5 else { continue }
                let light = min(color.redComponent, color.greenComponent, color.blueComponent)
                let dark = max(color.redComponent, color.greenComponent, color.blueComponent)
                if white ? light > 0.60 : dark < 0.17 {
                    bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        return try XCTUnwrap(bounds.isNull ? nil : bounds, name + " must render")
    }
}
