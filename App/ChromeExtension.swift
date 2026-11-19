import AppKit

/// The Chrome build of the extension, for Chrome-based browsers (Chrome, Edge, Brave, Arc…). They load it
/// with "Load unpacked", so it lives in a fixed folder outside the app bundle that survives updates; each
/// launch refreshes it, and the extension reloads itself when the app reports a newer version.
@MainActor
final class ChromeExtension: ObservableObject {
    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Soft Subs/Chrome Extension", isDirectory: true)
    private static let usedKey = "chromeExtensionUsed"

    /// Set once a Chrome-based browser has talked to the app, so the Safari setup banner can step aside.
    @Published private(set) var isInUse = UserDefaults.standard.bool(forKey: usedKey)

    init() {
        Self.install()
    }

    func markUsed() {
        guard !isInUse else { return }
        isInUse = true
        UserDefaults.standard.set(true, forKey: Self.usedKey)
    }

    /// Shows the folder in Finder and copies its path, for pasting into Load unpacked's ⌘⇧G box.
    func reveal() {
        Self.install()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.folder.path, forType: .string)
        NSWorkspace.shared.activateFileViewerSelecting([Self.folder])
    }

    private static func install() {
        guard let bundled = Bundle.main.url(forResource: "chrome-extension", withExtension: nil) else {
            DebugLog.log("no bundled Chrome extension")
            return
        }
        let files = FileManager.default
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            // Replace file by file rather than the whole folder, so a browser with it loaded never sees it missing.
            for name in try files.contentsOfDirectory(atPath: bundled.path) {
                let target = folder.appendingPathComponent(name)
                try? files.removeItem(at: target)
                try files.copyItem(at: bundled.appendingPathComponent(name), to: target)
            }
        } catch {
            DebugLog.log("couldn't install the Chrome extension: \(error.localizedDescription)")
        }
    }
}
