import Combine
import Foundation

struct TokenUsageRow: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var provider: String
    var project: String
    var model: String
    var day: String
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite: Int
    var cacheWrite1h: Int
    var calls: Int
    var machine: String? = nil
    var tokens: Int { input + output + cacheRead + cacheWrite + cacheWrite1h }
    var valid: Bool { [input, output, cacheRead, cacheWrite, cacheWrite1h, calls].allSatisfy { $0 >= 0 && $0 <= 1_000_000_000_000 } }
    func apiEquivalent(prices: [ModelPrice]) -> Double? {
        let price = prices.first { $0.model == model }
            ?? prices.first { model.hasPrefix($0.model + "-202") && model.count == $0.model.count + 9 }
        guard let price else { return nil }
        return (Double(input) * price.input + Double(output) * price.output + Double(cacheRead) * price.cacheRead
                + Double(cacheWrite) * price.cacheWrite + Double(cacheWrite1h) * price.cacheWrite * 1.6) / 1_000_000
    }
}

struct AnalyticsProgress: Decodable, Equatable, Sendable {
    var filesTotal: Int
    var filesComplete: Int
    var bytesTotal: Int
    var bytesRead: Int
    var recordsInvalid: Int? = nil
    var pendingTailFiles: Int? = nil
    var valid: Bool {
        filesTotal >= 0 && (0...filesTotal).contains(filesComplete)
            && bytesTotal >= 0 && (0...bytesTotal).contains(bytesRead)
            && (recordsInvalid ?? 0) >= 0 && (pendingTailFiles ?? 0) >= 0
    }
    var complete: Bool { filesComplete == filesTotal && bytesRead == bytesTotal && (recordsInvalid ?? 0) == 0 && (pendingTailFiles ?? 0) == 0 }
    var fraction: Double? { bytesTotal > 0 ? Double(bytesRead) / Double(bytesTotal) : nil }
    var label: String {
        "\(filesComplete)/\(filesTotal) arquivos · " + ByteCountFormatter.string(fromByteCount: Int64(bytesRead), countStyle: .file)
            + " de " + ByteCountFormatter.string(fromByteCount: Int64(bytesTotal), countStyle: .file)
    }
}

struct AnalyticsDocument: Decodable, Sendable {
    var rows: [TokenUsageRow]
    var incomplete: Bool
    var updatedAt: String
    var warnings: [String]
    var progress: AnalyticsProgress? = nil
    var valid: Bool {
        rows.allSatisfy { $0.valid && UsageDay.date($0.day) != nil && !$0.id.isEmpty }
            && UsageDates.parse(updatedAt) != nil && (progress?.valid ?? true)
    }
}

struct CollectorPolicy: Sendable {
    var maximumPasses = 160
    var maximumSeconds: TimeInterval = 15 * 60
    var stalledPasses = 3
    var byteBudget = 32 * 1024 * 1024
}

enum CollectorFailure: Error {
    case missingScript, missingPython, failed, invalidResponse
    var message: String {
        switch self {
        case .missingScript: "Coletor local ausente no pacote"
        case .missingPython: "Python 3 não está disponível para ler os registros locais"
        case .failed: "A coleta local falhou ou excedeu o tempo do lote; o progresso confirmado e a última leitura foram preservados."
        case .invalidResponse: "O coletor retornou dados incompatíveis; a última leitura foi preservada."
        }
    }
}

@MainActor
final class UsageAnalytics: ObservableObject {
    @Published var filter = AnalysisFilter()
    @Published private(set) var imported = ImportedUsage()
    private var measuredRows: [TokenUsageRow] = []
    private var localSnapshot: AnalyticsDocument?
    private var localCollectionFailed = false
    private let importURL: URL
    private var importsWritable = true
    private var importIssue: String?
    private let remoteURL: URL
    private let collector: @Sendable (Int) async throws -> AnalyticsDocument
    private let collectorPolicy: CollectorPolicy
    private var cancelRequested = false
    let machineID: String
    init(importURL: URL? = nil, defaults: UserDefaults = .standard, remoteURL: URL? = nil,
         collector: (@Sendable (Int) async throws -> AnalyticsDocument)? = nil, collectorPolicy: CollectorPolicy = .init()) {
        self.remoteURL = remoteURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/usage-island/analytics-vps.json")
        self.collector = collector ?? Self.collectBatch
        self.collectorPolicy = collectorPolicy
        self.importURL = importURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Usage Island/imported-usage.json")
        if let existing = defaults.string(forKey: "usageIsland.machineID"), UUID(uuidString: existing) != nil { machineID = existing }
        else { let id = UUID().uuidString; machineID = id; defaults.set(id, forKey: "usageIsland.machineID") }
        if let data = try? Data(contentsOf: self.importURL), data.count <= 12 * 1024 * 1024,
           let saved = try? JSONDecoder().decode(ImportedUsage.self, from: data), saved.entries.count <= 60_000,
           saved.entries.allSatisfy({ $0.row.valid && UsageDay.date($0.row.day) != nil && UUID(uuidString: $0.machineID) != nil && $0.machineName.count <= 80 }) {
            imported = saved; rows = saved.rows
        } else if FileManager.default.fileExists(atPath: self.importURL.path) {
            importsWritable = false; importIssue = "Não foi possível ler as coletas importadas. O arquivo original foi preservado."; issue = importIssue
        }
    }
    var filteredRows: [TokenUsageRow] { filter.apply(to: rows) }
    var portableExportIssue: String? {
        if refreshing { return "Aguarde a coleta local terminar antes de exportar." }
        if localCollectionFailed { return "Atualize a coleta local com sucesso antes de exportar." }
        return PortableUsage.exportIssue(for: localSnapshot)
    }
    var canExportPortableUsage: Bool { portableExportIssue == nil }
    func portableData(now: Date = .now, name: String = Host.current().localizedName ?? "Mac") throws -> Data {
        guard !refreshing, !localCollectionFailed, let snapshot = localSnapshot else { throw CocoaError(.fileWriteUnknown) }
        let package = try PortableUsage.localSnapshot(snapshot, machineID: machineID, name: name, now: now)
        let data = try JSONEncoder().encode(package); guard data.count <= 4 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }; return data
    }
    func importData(_ data: Data) throws {
        guard importsWritable else { throw CocoaError(.fileReadCorruptFile) }
        guard data.count <= 4 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let package = try JSONDecoder().decode(PortableUsage.self, from: data)
        var updated = imported; try updated.merge(package, localID: machineID)
        let encoded = try JSONEncoder().encode(updated); guard encoded.count <= 12 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        try FileManager.default.createDirectory(at: importURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try encoded.write(to: importURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: importURL.path)
        imported = updated; rows = measuredRows + updated.rows
    }
    @Published private(set) var rows: [TokenUsageRow] = []
    @Published private(set) var issue: String?
    @Published private(set) var incomplete = false
    @Published private(set) var updatedAt: Date?
    @Published private(set) var refreshing = false
    @Published private(set) var vpsUpdatedAt: Date?
    @Published private(set) var progress: AnalyticsProgress?
    @Published private(set) var collectionMessage: String?
    @Published private(set) var collectionPass = 0
    @Published private(set) var completingCollection = false
    private var lastAttempt = Date.distantPast

    func cancelCollection() {
        guard refreshing else { return }
        cancelRequested = true
        collectionMessage = "Parando ao terminar o lote atual; o progresso será preservado."
    }

    func refresh(prices: [ModelPrice], force: Bool = false, complete: Bool = false) async {
        guard !refreshing, Date().timeIntervalSince(lastAttempt) >= (force ? 5 : 300) else { return }
        refreshing = true; completingCollection = complete; cancelRequested = false
        lastAttempt = .now; collectionPass = 0
        collectionMessage = complete ? "Concluindo a coleta local em lotes…" : "Atualizando a coleta local…"
        defer { refreshing = false; completingCollection = false }
        let started = ProcessInfo.processInfo.systemUptime
        var previousProgress: AnalyticsProgress?
        var stalled = 0
        while true {
            if cancelRequested || Task.isCancelled {
                collectionMessage = "Coleta pausada. Os próximos lotes continuam do progresso salvo."
                return
            }
            collectionPass += 1
            let document: AnalyticsDocument
            do {
                document = try await collector(collectorPolicy.byteBudget)
                guard document.valid else { throw CollectorFailure.invalidResponse }
            } catch {
                localCollectionFailed = true
                issue = (error as? CollectorFailure)?.message ?? CollectorFailure.failed.message
                collectionMessage = "Coleta interrompida; atualize para retomar."
                return
            }
            apply(document)
            if !document.incomplete {
                collectionMessage = PortableUsage.exportIssue(for: document) == nil
                    ? "Coleta local concluída."
                    : "Varredura finalizada com pendências de cobertura. Confira os avisos abaixo."
                return
            }
            if !complete {
                collectionMessage = "Há arquivos pendentes. Use Concluir coleta para continuar agora."
                return
            }
            if let current = document.progress, let previous = previousProgress,
               current.bytesRead <= previous.bytesRead && current.filesComplete <= previous.filesComplete {
                stalled += 1
            } else { stalled = 0 }
            previousProgress = document.progress
            if stalled >= collectorPolicy.stalledPasses {
                collectionMessage = "A coleta não avançou nos últimos lotes. O progresso foi preservado; tente atualizar novamente."
                return
            }
            if collectionPass >= max(1, collectorPolicy.maximumPasses)
                || ProcessInfo.processInfo.systemUptime - started >= collectorPolicy.maximumSeconds {
                collectionMessage = "Coleta pausada no limite desta rodada. Use Concluir coleta para retomar."
                return
            }
            collectionMessage = cancelRequested ? "Parando ao terminar o lote atual; o progresso será preservado."
                : "Concluindo a coleta local · lote \(collectionPass + 1)…"
            await Task.yield()
        }
    }

    nonisolated private static func collectBatch(budget: Int) async throws -> AnalyticsDocument {
        guard let script = IslandResource.url("usage-analytics", extension: "py") else { throw CollectorFailure.missingScript }
        let executable = ["/opt/homebrew/bin/python3", "/usr/bin/python3", "/usr/local/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let executable else { throw CollectorFailure.missingPython }
        return try await Task.detached(priority: .utility) {
            guard let result = BoundedProcess.run(executable: executable, arguments: [script.path, "--budget", String(budget)], timeout: 35, outputLimit: 16 * 1024 * 1024),
                  result.status == 0 else { throw CollectorFailure.failed }
            guard let document = try? JSONDecoder().decode(AnalyticsDocument.self, from: result.output), document.valid else { throw CollectorFailure.invalidResponse }
            return document
        }.value
    }

    private func apply(_ document: AnalyticsDocument) {
        localSnapshot = document; localCollectionFailed = false
        progress = document.progress
        var combined = document.rows
        var warnings = document.warnings
        if let importIssue { warnings.append(importIssue) }
        vpsUpdatedAt = nil
        if let data = try? Data(contentsOf: remoteURL), data.count <= 4 * 1024 * 1024,
           let vps = try? JSONDecoder().decode(AnalyticsDocument.self, from: data), vps.rows.allSatisfy(\.valid),
           let captured = UsageDates.parse(vps.updatedAt) {
            combined += vps.rows.map { row in var row = row; row.id = "VPS|" + row.id; row.machine = "VPS"; return row }
            vpsUpdatedAt = captured
            if Date().timeIntervalSince(captured) > 3600 { warnings.append("Dados da VPS têm mais de 1h") }
            if vps.incomplete { warnings.append("Coleta inicial da VPS em andamento") }
            warnings += vps.warnings
        }
        measuredRows = combined; rows = combined + imported.rows; incomplete = document.incomplete; updatedAt = UsageDates.parse(document.updatedAt)
        issue = warnings.isEmpty ? nil : Array(Set(warnings)).sorted().joined(separator: " · ")
    }

    func rows(days: Int, now: Date = .now) -> [TokenUsageRow] {
        let cutoff = now.addingTimeInterval(-Double(days - 1) * 86400)
        let format = DateFormatter(); format.dateFormat = "yyyy-MM-dd"; format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT: 0)
        let first = format.string(from: cutoff)
        return rows.filter { $0.day >= first }
    }
    func export(prices: [ModelPrice]) throws -> Data {
        struct Export: Encodable { var label: String; var rows: [TokenUsageRow] }
        return try JSONEncoder().encode(Export(label: "Tokens locais medidos; preços de API são estimativas separadas da assinatura", rows: rows))
    }
}

enum IslandResource {
    static func url(_ name: String, extension ext: String) -> URL? {
        if let resource = Bundle.main.resourceURL?.appendingPathComponent("UsageIsland_UsageIsland.bundle"),
           let bundle = Bundle(url: resource), let url = bundle.url(forResource: name, withExtension: ext) { return url }
        return Bundle.module.url(forResource: name, withExtension: ext)
    }
}
