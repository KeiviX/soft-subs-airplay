import AppKit
import Foundation

/// Checks GitHub for a newer release and installs it: downloads the zip, swaps the app in place and relaunches.
/// The Safari extension lives inside the app, so it updates too.
@MainActor
final class Updater: ObservableObject {
    @Published private(set) var latestVersion: String?
    @Published private(set) var isInstalling = false
    @Published private(set) var error: String?

    private var downloadURL: URL?
    private var timer: Timer?
    private static let latestRelease = URL(string: "https://api.github.com/repos/KeiviX/soft-subs-airplay/releases/latest")!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Only installed copies update themselves; a development build in the repo's build/ folder doesn't.
    var canInstall: Bool {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().path
        return path == "/Applications" || path == NSHomeDirectory() + "/Applications"
    }

    var isUpdateAvailable: Bool {
        guard let latestVersion, downloadURL != nil else { return false }
        return Self.compare(latestVersion, Self.currentVersion) == .orderedDescending
    }

    init() {
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { await self?.check() }
        }
    }

    func check() async {
        var request = URLRequest(url: Self.latestRelease)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = release["tag_name"] as? String else { return }
        let assets = release["assets"] as? [[String: Any]] ?? []
        latestVersion = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        downloadURL = assets.lazy
            .first { ($0["name"] as? String).map { $0.hasPrefix("SoftSubs-") && $0.hasSuffix(".zip") && !$0.contains("Chrome") } ?? false }
            .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
        DebugLog.log("update check: current \(Self.currentVersion), latest \(latestVersion ?? "?")")
    }

    func install() {
        guard let downloadURL, canInstall else { return }
        isInstalling = true
        error = nil
        Task {
            do {
                let (zip, _) = try await URLSession.shared.download(from: downloadURL)
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SoftSubs-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path])
                let newApp = folder.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
                guard FileManager.default.fileExists(atPath: newApp.path) else { throw UpdateError.badDownload }
                relaunch(replacingWith: newApp)
            } catch {
                self.error = "Update failed: \(error.localizedDescription)"
                isInstalling = false
            }
        }
    }

    /// Hands over to a small shell script that waits for this app to quit, swaps the bundle and opens the new one.
    private func relaunch(replacingWith newApp: URL) {
        let app = Bundle.main.bundleURL.path
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(app)" && mv "\(newApp.path)" "\(app)" && xattr -dr com.apple.quarantine "\(app)" 2>/dev/null
        open "\(app)"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
        DebugLog.log("updating to \(latestVersion ?? "?")")
        NSApp.terminate(nil)
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw UpdateError.badDownload }
    }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: .numeric)
    }

    enum UpdateError: LocalizedError {
        case badDownload
        var errorDescription: String? { "the downloaded update was incomplete." }
    }
}
