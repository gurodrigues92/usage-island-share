import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = IslandCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        coordinator.start()
    }
}

// A menu-bar app must not die because a helper it spawned went away. `CodexUsageReader`
// writes JSON-RPC into `codex app-server`'s stdin; when that process exits early — which is
// what happens under launchd, whose PATH does not reach the CLI's own dependencies — the
// write lands on a closed pipe. A Swift executable does not ignore SIGPIPE by default, so
// the whole app was killed, and `try?` around the write never sees it: the signal arrives
// first. This cost a crash-looping login agent (`Broken pipe: 13`, no crash report, no log).
signal(SIGPIPE, SIG_IGN)

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
