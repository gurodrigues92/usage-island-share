import AppKit
import Combine
import Darwin
import Foundation

enum SessionApplication {
    @MainActor static func find(from pid: Int32) -> NSRunningApplication? {
        var current = pid
        var visited = Set<Int32>()
        for _ in 0..<24 {
            guard current > 1, visited.insert(current).inserted else { return nil }
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy != .prohibited { return app }
            var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
            current = info.kp_eproc.e_ppid
        }
        return nil
    }
}

@MainActor
final class MultiProviderActivity: ObservableObject {
    @Published private(set) var sessions: [UsageSource: [AgentSession]] = [:]
    private var task: Task<Void, Never>?
    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                let found = await Task.detached(priority: .utility) { ActivityFiles.read() }.value
                guard let self else { return }
                if self.sessions != found { self.sessions = found }
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }
    deinit { task?.cancel() }
}

enum ActivityFiles {
    static func tail(_ url: URL, limit: UInt64 = 256 * 1024) -> Data? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let end = try? file.seekToEnd(), (try? file.seek(toOffset: end > limit ? end - limit : 0)) != nil,
              let data = try? file.readToEnd() else { return nil }
        if end > limit, let first = data.firstIndex(of: 10) { return Data(data.suffix(from: data.index(after: first))) }
        return data
    }
    static func rows(_ data: Data) -> [[String: Any]] {
        data.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }
    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = .now) -> [UsageSource: [AgentSession]] {
        [.codex: codex(home: home, now: now), .opencode: opencode(home: home), .grok: grok(home: home, now: now)]
    }
    static func codex(home: URL, now: Date) -> [AgentSession] {
        let root = home.appendingPathComponent(".codex/sessions")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        var files: [(URL, Date)] = []; var count = 0
        while let url = enumerator.nextObject() as? URL, count < 10000 {
            count += 1
            guard url.pathExtension == "jsonl", let stamp = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(stamp) < 3600 else { continue }
            files.append((url, stamp))
        }
        return files.sorted { $0.1 > $1.1 }.prefix(16).compactMap { url, stamp in
            guard let data = tail(url) else { return nil }
            return codexSession(data, id: url.lastPathComponent, modifiedAt: stamp, now: now)
        }
    }
    static func codexSession(_ data: Data, id: String, modifiedAt: Date, now: Date) -> AgentSession? {
        let records = rows(data)
        var state: AgentSession.State?; var confirmed = false; var heuristic = false
        for record in records.reversed() {
            guard record["type"] as? String == "event_msg", let payload = record["payload"] as? [String: Any],
                  let kind = payload["type"] as? String else { continue }
            if ["turn_aborted", "task_aborted"].contains(kind) { return nil }
            if ["task_complete", "task_completed", "turn_completed"].contains(kind) { state = .idle; confirmed = true; break }
            if ["task_started", "turn_started"].contains(kind) { state = .busy; break }
        }
        if state == nil, now.timeIntervalSince(modifiedAt) < 30 { state = .busy; heuristic = true }
        guard let state, state == .idle || now.timeIntervalSince(modifiedAt) < 120 else { return nil }
        let meta = records.first { $0["type"] as? String == "session_meta" }?["payload"] as? [String: Any]
        let name = (meta?["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Sessão Codex"
        return .init(id: "codex." + id, name: name, detail: "Codex" + (heuristic ? " · atividade estimada" : ""),
                     state: state, waitingFor: nil, since: modifiedAt, applicationID: "com.openai.codex",
                     isHeuristic: heuristic, completionConfirmed: confirmed)
    }
    static func opencode(home: URL) -> [AgentSession] {
        let root = home.appendingPathComponent(".cache/usage-island/activity")
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles) else { return [] }
        return files.filter { $0.lastPathComponent.hasPrefix("opencode-") && $0.pathExtension == "json" }.prefix(32).flatMap { file -> [AgentSession] in
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 256 * 1024,
                  let data = try? Data(contentsOf: file), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  root["version"] as? Int == 1, let pid = (root["pid"] as? NSNumber)?.int32Value,
                  let started = root["startedAt"] as? Double, started.isFinite,
                  ProcessLiveness.isAlive(pid: pid, startedAt: Date(timeIntervalSince1970: started / 1000)),
                  let sessions = root["sessions"] as? [[String: Any]] else { return [] }
            return sessions.prefix(64).compactMap { row in
                guard let id = row["id"] as? String, id.count < 200,
                      let state = row["state"] as? String, ["busy", "waiting", "idle"].contains(state),
                      let since = row["since"] as? Double, since.isFinite else { return nil }
                return .init(id: "opencode.\(pid)." + id, name: String((row["name"] as? String ?? "Sessão OpenCode").prefix(200)),
                             detail: "OpenCode", state: state == "busy" ? .busy : state == "waiting" ? .waiting : .idle,
                             waitingFor: state == "waiting" ? "permissão ou resposta" : nil,
                             since: Date(timeIntervalSince1970: since / 1000), processID: pid, completionConfirmed: state == "idle")
            }
        }
    }
    static func grok(home: URL, now: Date) -> [AgentSession] {
        let url = home.appendingPathComponent(".grok/active_sessions.json")
        guard let data = try? Data(contentsOf: url), data.count < 512 * 1024,
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let registry = (json as? [[String: Any]]) ?? ((json as? [String: Any])?["sessions"] as? [[String: Any]]) ?? []
        let root = home.appendingPathComponent(".grok/sessions")
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return registry.prefix(32).compactMap { row in
            guard let id = row["session_id"] as? String, !id.isEmpty, !id.contains("/"), id != "..",
                  let pid = (row["pid"] as? NSNumber)?.int32Value,
                  ProcessLiveness.isAlive(pid: pid, startedAt: (row["opened_at"] as? String).flatMap(UsageDates.parse)),
                  let directory = folders.prefix(512).map({ $0.appendingPathComponent(id) }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
            let updates = directory.appendingPathComponent("updates.jsonl")
            guard let modified = try? updates.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) < 120, let data = tail(updates) else { return nil }
            let kind = rows(data).reversed().compactMap { record -> String? in
                let params = record["params"] as? [String: Any], update = params?["update"] as? [String: Any]
                let kind = update?["sessionUpdate"] as? String
                return kind == "hook_execution" ? nil : kind
            }.first
            let done = kind == "turn_completed"
            let name = (row["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Sessão Grok"
            return .init(id: "grok." + id, name: name, detail: "Grok" + (done ? "" : " · atividade estimada"),
                         state: done ? .idle : .busy, waitingFor: nil, since: modifiedAt(updates) ?? modified,
                         processID: pid, isHeuristic: !done, completionConfirmed: done)
        }
    }
    private static func modifiedAt(_ url: URL) -> Date? { try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
}
