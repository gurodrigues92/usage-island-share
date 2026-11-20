import AppKit
import Combine
import CryptoKit
import Foundation

extension IslandModel {
    func isEnabled(_ id: String) -> Bool { settings.value.rings.first { $0.id == id }?.enabled == true }

    func reconcileSettings(_ incoming: UsagePreferences? = nil) {
        let prefs = incoming ?? settings.value
        let existing = Dictionary(allSnapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        allSnapshots = prefs.rings.map { entry in
            var snapshot = existing[entry.id] ?? UsageSnapshot(source: entry.source, accountSlug: entry.accountSlug,
                percentUsed: nil, sessionPercent: nil, resetText: entry.source == .custom ? "Informe o uso nas configurações" : "Aguardando leitura",
                updatedAt: .distantPast, syncState: .loading)
            snapshot.entryID = entry.id; snapshot.customName = entry.displayName
            snapshot.customSymbol = entry.symbol.isEmpty ? nil : entry.symbol
            snapshot.preferredWindowID = entry.preferredWindow; snapshot.paused = !entry.enabled
            if entry.source == .custom {
                snapshot.percentUsed = entry.manualPercent; snapshot.updatedAt = entry.manualUpdatedAt ?? .distantPast
                snapshot.syncState = entry.manualPercent == nil ? .unavailable : .manual
                snapshot.fidelity = .manual; snapshot.resetText = "Leitura manual"; snapshot.windows = []
                snapshot.limitLabel = "Indicador manual"
            }
            return snapshot
        }
        if let selected, !prefs.rings.contains(where: { $0.id == selected && ($0.visible || $0.enabled) }) { dismiss() }
        dockActivity.ingest(sessionsByEntryID: claudeActivity.mapValues(\.sessions), rings: prefs.rings, now: .now)
        settingsRevision += 1
        if powerupsTask != nil { ensureClaudeMonitors() }
    }

    var availableRings: [RingPreference] {
        UsageSettings.defaults(profiles: claudeProfiles).filter { candidate in !settings.value.rings.contains { $0.id == candidate.id } }
    }

    func discoverAccounts() {
        claudeProfiles = ClaudeProfile.discover()
        // Discovery only populates the add picker; it never re-adds an icon the
        // person removed or changes the bar while they are reading a card.
        settingsRevision += 1
    }

    func ensureClaudeMonitors() {
        for profile in claudeProfiles {
            let id = ClaudeProfile.ringID(slug: profile.slug)
            guard isEnabled(id), sessionMonitors[id] == nil else { continue }
            let monitor = ClaudeSessionMonitor(directory: profile.sessionsDirectory)
            monitor.$activity.removeDuplicates().sink { [weak self] in self?.receiveClaudeActivity($0, entryID: id) }.store(in: &sessionSubscriptions)
            sessionMonitors[id] = monitor; monitor.start()
        }
    }

    func addCodexFolder(_ url: URL) -> Bool {
        let directory = url.standardizedFileURL.resolvingSymlinksInPath().path
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").resolvingSymlinksInPath().path
        guard directory != defaultPath, FileManager.default.fileExists(atPath: url.appendingPathComponent("auth.json").path),
              !settings.value.rings.contains(where: { $0.source == .codex && $0.directory == directory }) else { return false }
        let digest = SHA256.hash(data: Data(directory.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        settings.add(.init(id: "Codex-" + digest, source: .codex, accountSlug: digest,
                           name: "Codex · " + url.lastPathComponent, directory: directory))
        return true
    }

    func beginReading(_ id: String) {
        var state = health[id] ?? .init(); state.startedAt = .now; state.inFlight = true; health[id] = state
    }
    func finishReading(_ id: String, next: Date?) {
        var state = health[id] ?? .init(); state.finishedAt = .now; state.inFlight = false
        state.duration = state.startedAt.map { Date().timeIntervalSince($0) }; state.nextAttempt = next
        state.error = allSnapshots.first { $0.id == id }?.failureReason; health[id] = state
    }

    func recordReading(_ id: String) {
        guard let snapshot = allSnapshots.first(where: { $0.id == id }) else { return }
        history.record(snapshot, retentionDays: settings.value.retentionDays)
        let forecasts = Dictionary(snapshot.windows.compactMap { window -> (String, QuotaForecast)? in
            history.forecast(for: snapshot, windowID: window.id).map { (window.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        let events = alerts.review(snapshot, preferences: settings.value, forecasts: forecasts)
        if !events.isEmpty { Task { await notifications.send(events) } }
    }

    func refreshOne(_ id: String) {
        guard isEnabled(id), let entry = settings.value.rings.first(where: { $0.id == id }) else { return }
        if let state = health[id], state.inFlight || (state.error != nil && (state.nextAttempt ?? .distantPast) > .now) { return }
        Task {
            switch entry.source {
            case .claude: await refreshClaude()
            case .codex: await refreshCodex()
            case .grok: await refreshGrok()
            case .opencode: await refreshOpenCode()
            case .openrouter: await refreshOpenRouter()
            case .custom: break
            }
        }
    }

    func refreshOpenRouter() async {
        for entry in settings.value.rings where entry.source == .openrouter && entry.enabled {
            guard !openRouterInFlight.contains(entry.id), Date().timeIntervalSince(lastOpenRouterRead[entry.id] ?? .distantPast) >= 60 else { continue }
            openRouterInFlight.insert(entry.id); lastOpenRouterRead[entry.id] = .now; beginReading(entry.id)
            let reading = await OpenRouterUsageReader.read(account: entry.id)
            openRouterInFlight.remove(entry.id)
            guard isEnabled(entry.id), let index = allSnapshots.firstIndex(where: { $0.id == entry.id }) else { continue }
            if let reading {
                allSnapshots[index].percentUsed = reading.window?.percent
                allSnapshots[index].windows = reading.window.map { [$0] } ?? []
                allSnapshots[index].primaryWindowID = reading.window?.id
                allSnapshots[index].balanceText = reading.balance
                allSnapshots[index].updatedAt = .now; allSnapshots[index].syncState = .live
                allSnapshots[index].fidelity = .oficial; allSnapshots[index].failureReason = nil
                recordReading(entry.id)
            } else { allSnapshots[index].markFailed("Confira a chave OpenRouter no Keychain e a conexão") }
            finishReading(entry.id, next: await HTTPBackoff.shared.waiting(entry.id) ?? .now.addingTimeInterval(60))
        }
    }

    func startPowerups() {
        powerupsTask?.cancel()
        let monitor = MultiProviderActivity()
        activityMonitor = monitor
        activitySubscription = monitor.$sessions.dropFirst().sink { [weak self] sessions in self?.receiveExternalActivity(sessions) }
        monitor.start()
        powerupsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshOpenRouter()
                await self.services.refresh(enabled: self.settings.value.checkServiceStatus)
                await self.analytics.refresh(prices: self.settings.value.prices)
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    var mostRoom: UsageSnapshot? {
        snapshots.filter { $0.fidelity == .oficial && $0.syncState == .live && !$0.isStale() && !$0.paused && !$0.hasBlockedWindow && !$0.windows.isEmpty
            && $0.windows.allSatisfy { $0.resetsAt == nil || $0.resetsAt! > .now } }
            .max { lhs, rhs in
                let a = lhs.windows.map(\.percent).max() ?? 100, b = rhs.windows.map(\.percent).max() ?? 100
                if lhs.hasBlockedWindow != rhs.hasBlockedWindow { return lhs.hasBlockedWindow }
                return a > b
            }
    }

    func diagnosticData() throws -> Data {
        let now = Date()
        let records: [[String: Any]] = allSnapshots.enumerated().map { index, snapshot in
            let state = health[snapshot.id]
            var row: [String: Any] = ["account": "account-\(index + 1)", "provider": snapshot.source.rawValue,
                "state": snapshot.syncState.label, "paused": snapshot.paused, "windowCount": snapshot.windows.count]
            if snapshot.percentUsed != nil { row["readingAgeSeconds"] = max(0, now.timeIntervalSince(snapshot.updatedAt)) }
            if let duration = state?.duration { row["requestDurationSeconds"] = duration }
            if let next = state?.nextAttempt { row["nextAttemptInSeconds"] = max(0, next.timeIntervalSince(now)) }
            // Export known classifications only, not raw error strings or paths.
            row["hasError"] = snapshot.syncState == .failed || snapshot.failureReason != nil
            row["hostCollectionComplete"] = snapshot.hostSplit?.isComplete as Any? ?? NSNull()
            return row
        }
        return try JSONSerialization.data(withJSONObject: ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            "capturedAt": ISO8601DateFormatter().string(from: now), "connectors": records,
            "historySamples": history.samples.count, "historyHasError": history.issue != nil], options: [.prettyPrinted, .sortedKeys])
    }

    func receiveClaudeActivity(_ activity: SessionActivity?, entryID: String) {
        guard isEnabled(entryID) else { claudeActivity[entryID] = nil; updateDockActivity(); return }
        let before = claudeActivity[entryID]
        claudeActivity[entryID] = activity
        updateDockActivity()
        notifySessionTransitions(old: before?.sessions ?? [], current: activity?.sessions ?? [], warmed: before != nil)
    }
    func receiveExternalActivity(_ sessions: [UsageSource: [AgentSession]]) {
        for (source, list) in sessions {
            guard let entry = settings.value.rings.first(where: { $0.source == source && $0.directory == nil && $0.enabled }) else { continue }
            let old = claudeActivity[entry.id]?.sessions ?? []
            claudeActivity[entry.id] = SessionActivity(sessions: list)
            notifySessionTransitions(old: old, current: list, warmed: activityWarmed)
        }
        activityWarmed = true
        updateDockActivity()
    }
    func notifySessionTransitions(old: [AgentSession], current: [AgentSession], warmed: Bool) {
        guard warmed, settings.value.notifications, settings.value.notifySessions, !settings.value.isQuiet(at: .now) else { return }
        var events: [UsageAlert] = []
        for item in current {
            guard let previous = old.first(where: { $0.id == item.id }), previous.state == .busy else { continue }
            if item.state == .waiting || (item.state == .idle && item.completionConfirmed) {
                events.append(.init(id: "session|" + item.id + "|\(Int(item.since.timeIntervalSince1970))", kind: .session,
                                    title: item.state == .waiting ? "Uma sessão precisa de você" : "Uma sessão terminou",
                                    body: item.name + " · " + item.detail))
            }
        }
        if !events.isEmpty { Task { await notifications.send(events) } }
    }

    func openSession(_ session: AgentSession) {
        if let pid = session.processID, let app = SessionApplication.find(from: pid) { app.activate(options: []); return }
        if let bundle = session.applicationID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first { app.activate(options: []); return }
        openSessions()
    }
}
