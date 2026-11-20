import AppKit
import ServiceManagement

/// Keeps the Rust helper (Contents/MacOS/softsubs-helper) running as a login item, and reports how it's doing.
///
/// The helper does all the casting; this app only sets it up. launchd starts it at login and restarts it if it
/// exits, so the browser extension always finds it on port 47800.
@MainActor
final class HelperAgent: ObservableObject {
    static let shared = HelperAgent()

    enum State: Equatable {
        case starting
        case running
        case needsApproval
        case failed(String)
    }

    struct Status: Decodable {
        var version: String
        var lanAddress: String?
        var ffmpeg: Bool
        var phase: String
        var chromeUsed: Bool?
        var startedAt: TimeInterval?
        var executable: String?
    }

    static let port = 47800
    private static let plistName = "com.keivi.softsubs.helper.plist"

    @Published private(set) var state = State.starting
    @Published private(set) var status: Status?

    private let service = SMAppService.agent(plistName: plistName)
    private var timer: Timer?
    private var unreachableSince: Date?
    private var restarted = false
    var onChromeUsed: (() -> Void)?

    var bundledHelper: URL? { Bundle.main.url(forAuxiliaryExecutable: "softsubs-helper") }

    func start() {
        guard timer == nil else { return }
        register()
        Task { await poll() }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
    }

    func register() {
        switch service.status {
        case .enabled:
            return
        case .requiresApproval:
            state = .needsApproval
            return
        default:
            do {
                try service.register()
                DebugLog.log("registered the helper login item (status \(service.status.rawValue))")
            } catch {
                DebugLog.log("couldn't register the helper: \(error.localizedDescription)")
                state = .failed("macOS didn't allow the background helper: \(error.localizedDescription)")
                return
            }
            if service.status == .requiresApproval { state = .needsApproval }
        }
    }

    /// Stops the helper until the app next starts it (at login, or when the browser extension needs it).
    func stop() async {
        timer?.invalidate()
        timer = nil
        do {
            try await service.unregister()
            DebugLog.log("helper stopped (unregistered)")
        } catch {
            DebugLog.log("couldn't unregister the helper: \(error.localizedDescription)")
        }
    }

    /// Whether the app itself (and so the helper) starts at login.
    var startsAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                DebugLog.log("couldn't change Start at Login: \(error.localizedDescription)")
            }
            objectWillChange.send()
        }
    }

    /// One line for the menu bar menu.
    var menuStatus: String {
        switch state {
        case .starting: "Starting…"
        case .running: status?.phase.hasPrefix("Open a video") == true ? "Ready to cast" : (status?.phase ?? "Ready to cast")
        case .needsApproval: "Needs approval in Login Items"
        case .failed: "Not running"
        }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Asks the helper how it is. A helper that's older than the bundled copy (after an update), or that isn't
    /// the bundled copy at all (one started by hand), is asked to quit; launchd then starts the bundled one.
    func poll() async {
        if service.status == .requiresApproval {
            state = .needsApproval
            return
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/api/status")!)
        request.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let status = try? JSONDecoder().decode(Status.self, from: data) else {
            self.status = nil
            let since = unreachableSince ?? Date()
            unreachableSince = since
            if Date().timeIntervalSince(since) > 15 {
                state = .failed("The helper isn't responding. Check the log, or restart your Mac.")
            } else if state != .needsApproval {
                state = .starting
            }
            return
        }
        unreachableSince = nil
        self.status = status
        state = .running
        if status.chromeUsed == true { onChromeUsed?() }
        if !restarted, isOutdated(status) {
            restarted = true
            DebugLog.log("restarting the helper (running \(status.executable ?? "?"), bundled \(bundledHelper?.path ?? "?"))")
            var quit = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/api/quit")!)
            quit.httpMethod = "POST"
            _ = try? await URLSession.shared.data(for: quit)
            state = .starting
        }
    }

    private func isOutdated(_ status: Status) -> Bool {
        guard let bundled = bundledHelper else { return false }
        // A helper too old to say where it's running from is older than any bundled copy.
        guard let running = status.executable, status.startedAt != nil else { return true }
        if URL(fileURLWithPath: running).resolvingSymlinksInPath() != bundled.resolvingSymlinksInPath() {
            return true
        }
        let modified = (try? bundled.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, let started = status.startedAt {
            return modified.timeIntervalSince1970 > started + 1
        }
        return false
    }
}
