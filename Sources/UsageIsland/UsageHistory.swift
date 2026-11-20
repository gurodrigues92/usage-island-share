import Combine
import Foundation

actor HistoryDisk {
    private var writtenRevision = -1
    func write(_ samples: [QuotaSample], to url: URL, revision: Int) throws {
        guard revision > writtenRevision else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(HistoryDocument(samples: samples))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        writtenRevision = revision
    }
}

struct HistoryDocument: Codable, Sendable { var version = 1; var samples: [QuotaSample] }

@MainActor
final class UsageHistory: ObservableObject {
    @Published private(set) var samples: [QuotaSample] = []
    @Published private(set) var issue: String?
    private let url: URL
    private let disk = HistoryDisk()
    private var revision = 0
    private var pending: Task<Void, Never>?
    private var writable = true
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Usage Island/quota-history.json")
    }

    init(url: URL = defaultURL) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 32 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            let saved = try JSONDecoder().decode(HistoryDocument.self, from: Data(contentsOf: url))
            guard saved.version == 1, saved.samples.allSatisfy({ $0.window.valid && $0.capturedAt.timeIntervalSince1970.isFinite }) else { throw CocoaError(.fileReadCorruptFile) }
            samples = saved.samples.sorted { $0.capturedAt < $1.capturedAt }
        } catch {
            writable = false
            issue = "Histórico salvo não pôde ser aberto. A cópia original foi preservada."
        }
    }

    @discardableResult
    func record(_ snapshot: UsageSnapshot, retentionDays: Int, now: Date = .now) -> [QuotaSample] {
        guard snapshot.syncState == .live, snapshot.fidelity == .oficial, !snapshot.isStale(now: now),
              snapshot.updatedAt <= now.addingTimeInterval(60) else { return [] }
        var added: [QuotaSample] = []
        for window in snapshot.windows where window.valid {
            if let reset = window.resetsAt, reset <= snapshot.updatedAt { continue }
            let last = samples.last { $0.entryID == snapshot.id && $0.window.id == window.id }
            guard last == nil || snapshot.updatedAt > last!.capturedAt else { continue }
            let sameCycle = last != nil && last?.window.resetsAt == window.resetsAt
            let corrected = sameCycle && (last!.window.percent - window.percent >= 2)
            let epoch = sameCycle ? (last!.epoch + (corrected ? 1 : 0)) : 0
            let sample = QuotaSample(entryID: snapshot.id, source: snapshot.source.rawValue, window: window,
                                     capturedAt: snapshot.updatedAt, epoch: epoch)
            // Five-minute buckets preserve the latest observation; new grants and
            // resets always get their own point, even inside the same bucket.
            if let last, sameCycle, !corrected,
               Int(last.capturedAt.timeIntervalSince1970 / 300) == Int(sample.capturedAt.timeIntervalSince1970 / 300),
               let index = samples.lastIndex(where: { $0.id == last.id }) {
                samples[index] = sample
            } else { samples.append(sample) }
            added.append(sample)
        }
        guard !added.isEmpty else { return [] }
        trim(retentionDays: retentionDays, now: now)
        revision += 1
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            await self?.flush()
        }
        return added
    }

    func trim(retentionDays: Int, now: Date = .now) {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        samples.removeAll { $0.capturedAt < cutoff || $0.capturedAt > now.addingTimeInterval(60) }
        var compacted: [String: QuotaSample] = [:]
        var recent: [QuotaSample] = []
        for sample in samples {
            if now.timeIntervalSince(sample.capturedAt) > 30 * 86400 {
                let key = sample.series + "|\(sample.epoch)|\(Int(sample.capturedAt.timeIntervalSince1970 / 3600))"
                if compacted[key] == nil || compacted[key]!.window.percent <= sample.window.percent { compacted[key] = sample }
            } else { recent.append(sample) }
        }
        samples = (recent + Array(compacted.values)).sorted { $0.capturedAt < $1.capturedAt }
        if samples.count > 100_000 { samples = Array(samples.suffix(100_000)) }
    }

    func flush() async {
        guard writable else { return }
        do { try await disk.write(samples, to: url, revision: revision); issue = nil }
        catch { issue = "Falha ao salvar histórico; as leituras atuais continuam disponíveis." }
    }

    func forecast(for snapshot: UsageSnapshot, windowID: String? = nil, now: Date = .now) -> QuotaForecast? {
        guard snapshot.syncState == .live, snapshot.fidelity == .oficial, !snapshot.paused, !snapshot.isStale(now: now) else { return nil }
        let id = windowID ?? snapshot.selectedWindow?.id
        guard let window = snapshot.windows.first(where: { $0.id == id }), window.valid,
              let reset = window.resetsAt, reset > now else { return nil }
        let series = samples.filter { $0.entryID == snapshot.id && $0.window.id == id && $0.window.resetsAt == reset }
        return QuotaForecast.calculate(samples: series, now: now, staleAfter: snapshot.staleAfter)
    }

    func exportJSON() throws -> Data { try JSONEncoder().encode(HistoryDocument(samples: samples)) }
    func exportCSV() -> String {
        func cell(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let format = ISO8601DateFormatter()
        return "provider,account,window,captured_at,used_percent,resets_at,epoch\n" + samples.map {
            [cell($0.source), cell($0.entryID), cell($0.window.title), cell(format.string(from: $0.capturedAt)),
             String($0.window.percent), cell($0.window.resetsAt.map(format.string) ?? ""), String($0.epoch)].joined(separator: ",")
        }.joined(separator: "\n")
    }

    func clear() async throws {
        pending?.cancel()
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = url.deletingLastPathComponent().appendingPathComponent("quota-history-backup-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: url, to: backup)
        }
        samples = []; writable = true; revision += 1
        try await disk.write([], to: url, revision: revision); issue = nil
    }
}
