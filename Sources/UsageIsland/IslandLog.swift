import Foundation

/// Rastro mínimo em `~/Library/Logs/UsageIsland/stderr.log`, escrito pelo laço de leitura.
///
/// Um batimento periódico permite identificar falhas ou leituras antigas.
enum IslandLog {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MM-yyyy HH:mm:ss"
        formatter.timeZone = .current
        return formatter
    }()

    static func write(_ message: String) {
        let line = "[\(formatter.string(from: .now))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}
