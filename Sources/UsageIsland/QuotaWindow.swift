import Foundation

struct QuotaWindow: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var percent: Double
    var resetsAt: Date? = nil
    var duration: TimeInterval? = nil
    var blocked = false

    var valid: Bool {
        UsageValidation.percent(percent) != nil
            && (duration == nil || (duration!.isFinite && duration! > 0 && duration! <= 366 * 86400))
            && (resetsAt == nil || (resetsAt!.timeIntervalSince1970.isFinite && (0...40_000_000_000).contains(resetsAt!.timeIntervalSince1970)))
    }
    func resetText(now: Date = .now) -> String {
        guard let reset = resetsAt else { return "Reset não informado" }
        guard reset > now else { return "Aguardando confirmar o reset" }
        let seconds = max(1, Int(reset.timeIntervalSince(now)))
        if seconds >= 86400 { return "Reinicia em \(seconds / 86400)d \((seconds % 86400) / 3600)h" }
        if seconds >= 3600 { return "Reinicia em \(seconds / 3600)h \((seconds % 3600) / 60)min" }
        return "Reinicia em \(max(1, seconds / 60))min"
    }
}

struct QuotaSample: Codable, Equatable, Identifiable, Sendable {
    var entryID: String
    var source: String
    var window: QuotaWindow
    var capturedAt: Date
    var epoch: Int
    var series: String { entryID + "|" + window.id + "|" + (window.resetsAt.map { String(Int64($0.timeIntervalSince1970)) } ?? "unknown") }
    var id: String { series + "|\(epoch)|\(capturedAt.timeIntervalSince1970)" }
}

struct QuotaForecast: Equatable, Sendable {
    enum Confidence: String, Sendable { case low = "Baixa", medium = "Moderada", high = "Alta" }
    var pointsPerHour: Double
    var projectedAtReset: Double
    var runsOutAt: Date?
    var confidence: Confidence
    var atRisk: Bool { projectedAtReset > 100 }

    static func calculate(samples: [QuotaSample], now: Date = .now, staleAfter: TimeInterval) -> Self? {
        let ordered = samples.sorted { $0.capturedAt < $1.capturedAt }
        guard let last = ordered.last, last.window.valid, let reset = last.window.resetsAt,
              reset > now, now.timeIntervalSince(last.capturedAt) >= -60,
              now.timeIntervalSince(last.capturedAt) <= staleAfter else { return nil }
        let lookback: TimeInterval = (last.window.duration ?? 86400) <= 6 * 3600 ? 3600 : 6 * 3600
        let points = ordered.filter { $0.entryID == last.entryID && $0.series == last.series && $0.epoch == last.epoch
            && last.capturedAt.timeIntervalSince($0.capturedAt) <= lookback }
        guard points.count >= 3, let first = points.first,
              last.capturedAt.timeIntervalSince(first.capturedAt) >= 15 * 60,
              last.window.percent - first.window.percent >= 0.25 else { return nil }
        // A correction starts a new epoch in the archive. Remaining negative slopes
        // indicate a malformed series and must not produce a plausible forecast.
        guard zip(points, points.dropFirst()).allSatisfy({ $0.window.percent <= $1.window.percent + 0.01 }) else { return nil }
        let xs = points.map { $0.capturedAt.timeIntervalSince(first.capturedAt) / 3600 }
        let ys = points.map { $0.window.percent }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        let denominator = xs.reduce(0) { $0 + pow($1 - mx, 2) }
        guard denominator > 0 else { return nil }
        let rate = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / denominator
        guard rate.isFinite, rate > 0 else { return nil }
        let eta = last.capturedAt.addingTimeInterval(max(0, 100 - last.window.percent) / rate * 3600)
        let projected = last.window.percent + reset.timeIntervalSince(last.capturedAt) / 3600 * rate
        guard projected.isFinite else { return nil }
        let coverage = last.capturedAt.timeIntervalSince(first.capturedAt)
        let confidence: Confidence = points.count >= 8 && coverage >= 3600 ? .high : (points.count >= 4 && coverage >= 1800 ? .medium : .low)
        return .init(pointsPerHour: rate, projectedAtReset: projected, runsOutAt: eta < reset ? eta : nil, confidence: confidence)
    }
}
