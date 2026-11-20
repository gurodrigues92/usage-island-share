import Foundation

/// Resolve picker choices before walking the archive. Computing a selected window
/// inside a per-sample filter rescanned the entire archive for every observation.
struct QuotaHistorySelection {
    struct Point: Identifiable {
        var sample: QuotaSample
        var segment: String
        var id: String { sample.id }
    }
    let entryID: String
    let windowID: String
    let windows: [QuotaWindow]
    let points: [Point]

    init(entryIDs: [String], samples: [QuotaSample], preferredEntryID: String,
         preferredWindowID: String, days: Int, now: Date = .now) {
        let recordedEntries = Set(samples.map(\.entryID))
        let selectedEntry = entryIDs.contains(preferredEntryID) ? preferredEntryID
            : entryIDs.first(where: { recordedEntries.contains($0) }) ?? entryIDs.first ?? ""
        entryID = selectedEntry
        var seen = Set<String>()
        var available: [QuotaWindow] = []
        for sample in samples.reversed() where sample.entryID == selectedEntry {
            if seen.insert(sample.window.id).inserted { available.append(sample.window) }
        }
        windows = available
        let selectedWindow = seen.contains(preferredWindowID) ? preferredWindowID : available.first?.id ?? ""
        windowID = selectedWindow
        let cut = now.addingTimeInterval(-Double(days) * 86400)
        var selectedPoints: [Point] = []
        var segment = 0
        var last: QuotaSample?
        for sample in samples where sample.entryID == selectedEntry && sample.window.id == selectedWindow && sample.capturedAt >= cut {
            if let previous = last, sample.series != previous.series || sample.epoch != previous.epoch
                || sample.capturedAt.timeIntervalSince(previous.capturedAt) > 3600 { segment += 1 }
            selectedPoints.append(Point(sample: sample, segment: "segment-\(segment)"))
            last = sample
        }
        points = selectedPoints
    }
}
