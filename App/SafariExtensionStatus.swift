import AppKit
import SafariServices

/// Tracks whether the Soft Subs extension is turned on in Safari, so the app can walk people through enabling it.
@MainActor
final class SafariExtensionStatus: ObservableObject {
    static let identifier = "com.keivi.softsubs.extension"

    @Published private(set) var isEnabled = true

    private var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: Self.identifier) { state, error in
            let enabled = state?.isEnabled ?? false
            if let error { DebugLog.log("extension state error: \(error.localizedDescription)") }
            Task { @MainActor in self.isEnabled = enabled }
        }
    }

    func openSafariSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: Self.identifier) { error in
            if let error { DebugLog.log("couldn't open Safari settings: \(error.localizedDescription)") }
        }
    }
}
