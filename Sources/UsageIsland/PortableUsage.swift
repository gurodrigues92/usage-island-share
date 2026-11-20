import Foundation

struct PortableUsage: Codable {
    var version = 1
    var machineID: String
    var machineName: String
    var capturedAt: Date
    var firstDay: String
    var lastDay: String
    var rows: [TokenUsageRow]
    /// Replacement imports must represent one complete, recent collection.
    /// A new click timestamp must never make old or uncollected counters look newer.
    static func exportIssue(for document: AnalyticsDocument?, now: Date = .now) -> String? {
        guard let document else { return "Atualize os dados locais antes de exportar." }
        guard document.valid else { return "A coleta local contém dados incompatíveis. Atualize antes de exportar." }
        guard !document.incomplete else { return "Há arquivos pendentes. Conclua a coleta antes de exportar." }
        if let invalid = document.progress?.recordsInvalid, invalid > 0 {
            return "Há \(invalid) registros inválidos na fonte local. A cobertura ainda não permite exportar."
        }
        if let tails = document.progress?.pendingTailFiles, tails > 0 {
            return "Há \(tails) arquivos com registros ainda incompletos. Atualize quando esses registros forem concluídos."
        }
        guard document.progress?.complete ?? true else { return "A leitura não cobriu todos os arquivos. Conclua a coleta antes de exportar." }
        guard document.warnings.isEmpty else { return "Há avisos de cobertura na coleta local. Confira os avisos antes de exportar." }
        guard let captured = UsageDates.parse(document.updatedAt), captured <= now.addingTimeInterval(300),
              now.timeIntervalSince(captured) <= 600 else { return "A coleta local está desatualizada. Atualize os dados antes de exportar." }
        return nil
    }
    static func localSnapshot(_ document: AnalyticsDocument, machineID: String, name: String, now: Date = .now) throws -> PortableUsage {
        guard exportIssue(for: document, now: now) == nil, let captured = UsageDates.parse(document.updatedAt) else { throw CocoaError(.fileWriteUnknown) }
        let range = AnalysisFilter(days: 7).interval(now: captured)
        let first = UsageDay.string(range.start), end = UsageDay.string(range.end)
        let package = PortableUsage(machineID: machineID, machineName: String(name.prefix(80)), capturedAt: captured,
                                    firstDay: first, lastDay: UsageDay.string(range.end.addingTimeInterval(-1)),
                                    rows: document.rows.filter { $0.machine == nil && $0.day >= first && $0.day < end })
        guard package.valid else { throw CocoaError(.fileWriteUnknown) }
        return package
    }
    var valid: Bool {
        version == 1 && UUID(uuidString: machineID) != nil && !machineName.isEmpty && machineName.count <= 80
            && capturedAt.timeIntervalSince1970.isFinite && capturedAt <= Date.now.addingTimeInterval(300)
            && UsageDay.date(firstDay) != nil && UsageDay.date(lastDay) != nil && firstDay <= lastDay
            && UsageDay.date(lastDay)!.timeIntervalSince(UsageDay.date(firstDay)!) <= 6 * 86400
            && rows.count <= 30_000 && Set(rows.map(\.id)).count == rows.count
            && rows.allSatisfy { row in row.valid && row.day >= firstDay && row.day <= lastDay && UsageDay.date(row.day) != nil
                && [row.id, row.provider, row.project, row.model].allSatisfy { !$0.isEmpty && $0.count <= 600 } }
    }
}

struct ImportedUsage: Codable {
    struct Entry: Codable { var machineID: String; var machineName: String; var capturedAt: Date; var row: TokenUsageRow }
    var entries: [Entry] = []
    var revisions: [String: Date] = [:]
    mutating func merge(_ package: PortableUsage, localID: String) throws {
        guard package.valid, package.machineID != localID else { throw CocoaError(.fileReadCorruptFile) }
        var day = UsageDay.date(package.firstDay)!
        while UsageDay.string(day) <= package.lastDay {
            let dayString = UsageDay.string(day); let key = package.machineID + "|" + dayString
            if revisions[key] == nil || revisions[key]! <= package.capturedAt {
                entries.removeAll { $0.machineID == package.machineID && $0.row.day == dayString }
                entries += package.rows.filter { $0.day == dayString }.map {
                    Entry(machineID: package.machineID, machineName: package.machineName, capturedAt: package.capturedAt, row: $0)
                }
                revisions[key] = package.capturedAt
            }
            day = UsageDay.calendar.date(byAdding: .day, value: 1, to: day)!
        }
        guard entries.count <= 60_000 else { throw CocoaError(.fileReadTooLarge) }
    }
    var rows: [TokenUsageRow] {
        entries.map { entry in
            var row = entry.row
            row.id = "import|" + entry.machineID + "|" + row.id
            row.machine = entry.machineName + " · " + String(entry.machineID.prefix(4))
            return row
        }
    }
}
