import AppKit
import SwiftUI

/// Soft Subs' Mac app. The casting is done by a background helper (see HelperAgent); this app installs it as a
/// login item, carries the Safari extension, and shows setup help and updates when you open it.
@main
struct SoftSubsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var helper = HelperAgent.shared
    @StateObject private var safariExtension = SafariExtensionStatus()
    @StateObject private var chromeExtension = ChromeExtension()
    @StateObject private var updater = Updater()

    var body: some Scene {
        Window("Soft Subs", id: "main") {
            ContentView()
                .environmentObject(helper)
                .environmentObject(safariExtension)
                .environmentObject(chromeExtension)
                .environmentObject(updater)
                .onAppear { helper.onChromeUsed = { [weak chromeExtension] in chromeExtension?.markUsed() } }
        }
        .windowResizability(.contentSize)

        // Soft Subs lives in the menu bar: no Dock icon, and the window only when asked for.
        MenuBarExtra("Soft Subs", systemImage: "captions.bubble") {
            MenuContent(chromeExtension: chromeExtension)
                .environmentObject(helper)
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject private var helper: HelperAgent
    let chromeExtension: ChromeExtension
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(helper.menuStatus)
        Divider()
        Button("Open Soft Subs…") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Show Chrome Extension Folder") { chromeExtension.reveal() }
        Toggle("Start at Login", isOn: Binding(get: { helper.startsAtLogin }, set: { helper.startsAtLogin = $0 }))
        Divider()
        Button("Quit Soft Subs") {
            Task {
                await helper.stop()
                NSApp.terminate(nil)
            }
        }
        .keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let setUpKey = "setUpOnce"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in HelperAgent.shared.start() }
        // Start at Login is on unless the person turns it off; registering again is harmless.
        if !UserDefaults.standard.bool(forKey: Self.setUpKey) {
            UserDefaults.standard.set(true, forKey: Self.setUpKey)
            Task { @MainActor in HelperAgent.shared.startsAtLogin = true }
            return // first run: keep the window, it has the setup steps
        }
        // Started at login, or by the browser extension (softsubs://) to bring the helper back: no window.
        // Opened by the person from Finder or Spotlight: show it.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        let byURL = event?.eventClass == AEEventClass(kInternetEventClass)
            || (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool) == false
        if atLogin || byURL {
            DispatchQueue.main.async {
                for window in NSApp.windows where window.identifier?.rawValue.contains("main") == true || window.title == "Soft Subs" {
                    window.close()
                }
            }
        }
    }

    /// Opening the app again (Finder, Spotlight, Dock) while it's running shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in NSApp.windows where window.title == "Soft Subs" {
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct ContentView: View {
    @EnvironmentObject private var helper: HelperAgent
    @EnvironmentObject private var safariExtension: SafariExtensionStatus
    @EnvironmentObject private var chromeExtension: ChromeExtension
    @EnvironmentObject private var updater: Updater

    var body: some View {
        VStack(spacing: 0) {
            if updater.isUpdateAvailable {
                UpdateBanner(updater: updater)
            }
            ExtensionBanner(safari: safariExtension, chrome: chromeExtension)

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Soft Subs")
                            .font(.title2.weight(.semibold))
                        HStack(spacing: 6) {
                            Circle()
                                .fill(stateColor)
                                .frame(width: 8, height: 8)
                            Text(stateText)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }

                if helper.state == .needsApproval {
                    HStack {
                        Text("Allow Soft Subs in Login Items so it can run in the background.")
                            .font(.callout)
                        Spacer()
                        Button("Open Login Items", action: helper.openLoginItems)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("How to cast")
                        .font(.headline)
                    Text("Play a video in Safari or Chrome, click the Soft Subs button in the toolbar, pick your TV and click Send. "
                         + "A Soft Subs tab opens to control playback. You can close this window: Soft Subs keeps running in the menu bar "
                         + "(the captions icon), where you can also quit it when you're not casting.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let status = helper.status, !status.ffmpeg {
                    Label("ffmpeg isn't installed. It's needed for most streams: run  brew install ffmpeg  in Terminal.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                HStack {
                    Text(footer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Log") {
                        NSWorkspace.shared.open(DebugLog.folder.appendingPathComponent("soft-subs.log"))
                    }
                    .controlSize(.small)
                    Button("Quit Soft Subs") {
                        Task {
                            await helper.stop()
                            NSApp.terminate(nil)
                        }
                    }
                    .controlSize(.small)
                    .help("Stops casting in the background until you next log in or use the extension.")
                }
            }
            .padding(18)
        }
        .frame(width: 520)
    }

    private var stateText: String {
        switch helper.state {
        case .starting: "Starting…"
        case .running: helper.status?.phase ?? "Ready"
        case .needsApproval: "Waiting for your approval in Login Items"
        case .failed(let message): message
        }
    }

    private var stateColor: Color {
        switch helper.state {
        case .running: .green
        case .starting, .needsApproval: .orange
        case .failed: .red
        }
    }

    private var footer: String {
        let version = "Version \(Updater.currentVersion)"
        guard let status = helper.status else { return version }
        let address = status.lanAddress.map { "serving on \($0):\(HelperAgent.port)" } ?? "not on a local network"
        return "\(version) · helper \(status.version) · \(address)"
    }
}

/// Setup help until the extension is on in Safari or a Chrome-based browser has used it.
struct ExtensionBanner: View {
    @ObservedObject var safari: SafariExtensionStatus
    @ObservedObject var chrome: ChromeExtension
    @State private var showChromeSteps = false

    var body: some View {
        if !safari.isEnabled && !chrome.isInUse {
            if showChromeSteps { chromeSteps } else { safariSteps }
        }
    }

    private var safariSteps: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "puzzlepiece.extension")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Turn on the Soft Subs extension in Safari")
                    .font(.headline)
                Text("Enable it and set it to Allow on every website. Not listed? Safari → Settings → Advanced → "
                     + "Show features for web developers, then Develop → Allow Unsigned Extensions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button("Open Safari Settings", action: safari.openSafariSettings)
                Button("Using Chrome?") { showChromeSteps = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.12))
    }

    private var chromeSteps: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "puzzlepiece.extension")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Soft Subs to Chrome, Edge, Brave or another Chrome-based browser")
                    .font(.headline)
                Text("Open its extensions page (chrome://extensions), turn on Developer mode, click Load unpacked, "
                     + "press ⌘⇧G, paste (the button below copies the folder's path) and press Return, then Select.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button("Show Extension Folder", action: chrome.reveal)
                Button("Using Safari?") { showChromeSteps = false }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.12))
    }
}

struct UpdateBanner: View {
    @ObservedObject var updater: Updater

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Soft Subs \(updater.latestVersion ?? "") is available")
                    .font(.headline)
                Text(updater.error ?? (updater.canInstall
                    ? "Updates the app, its helper and its Safari extension, then reopens."
                    : "Move Soft Subs to Applications to update it from here, or download it from GitHub."))
                    .font(.caption)
                    .foregroundStyle(updater.error == nil ? Color.secondary : Color.red)
            }
            Spacer()
            if updater.canInstall {
                Button(updater.isInstalling ? "Updating…" : "Update now", action: updater.install)
                    .disabled(updater.isInstalling)
            } else {
                Link("Download", destination: URL(string: "https://github.com/KeiviX/soft-subs-airplay/releases/latest")!)
            }
        }
        .padding(12)
        .background(.blue.opacity(0.12))
    }
}
