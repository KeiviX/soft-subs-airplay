import AppKit
import AVKit
import SwiftUI

@main
struct SoftSubsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var cast = CastController()
    @StateObject private var safariExtension = SafariExtensionStatus()
    @StateObject private var updater = Updater()

    var body: some Scene {
        Window("Soft Subs", id: "main") {
            ContentView()
                .environmentObject(cast)
                .environmentObject(safariExtension)
                .environmentObject(updater)
                .onOpenURL { _ in NSApp.activate() }
        }
        .windowResizability(.contentMinSize)
    }
}

/// Keeps the stream server running after the window is closed.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct ContentView: View {
    @EnvironmentObject private var cast: CastController
    @EnvironmentObject private var safariExtension: SafariExtensionStatus
    @EnvironmentObject private var updater: Updater

    var body: some View {
        VStack(spacing: 0) {
            if updater.isUpdateAvailable {
                UpdateBanner(updater: updater)
            }
            if !safariExtension.isEnabled {
                ExtensionBanner(status: safariExtension)
            }
            VideoPlayer(player: cast.player)
                .overlay {
                    if cast.phase == .idle {
                        Label("Nothing playing", systemImage: "captions.bubble")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black)
                    }
                }
                .frame(minHeight: 260)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cast.title.isEmpty ? "Soft Subs" : cast.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(cast.statusText)
                            .font(.callout)
                            .foregroundStyle(statusColor)
                            .lineLimit(2)
                    }
                    Spacer()
                    if cast.phase != .idle {
                        Button("Stop", action: cast.stop)
                    }
                }

                if cast.phase == .playing {
                    TVButtons(cast: cast, display: cast.tvDisplay)
                    HStack(spacing: 8) {
                        Toggle("Subtitles", isOn: $cast.subtitlesOn)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        Spacer()
                        Group {
                            Text("Timing")
                                .foregroundStyle(.secondary)
                            Button("Earlier", systemImage: "minus") { cast.nudgeSubtitles(by: -0.25) }
                                .labelStyle(.iconOnly)
                                .help("Show subtitles 0.25 s earlier")
                            Text(String(format: "%+.2f s", cast.subtitleOffset))
                                .monospacedDigit()
                                .frame(width: 64)
                            Button("Later", systemImage: "plus") { cast.nudgeSubtitles(by: 0.25) }
                                .labelStyle(.iconOnly)
                                .help("Show subtitles 0.25 s later")
                        }
                        .disabled(!cast.subtitlesOn)
                    }
                    if !cast.subtitleSummary.isEmpty {
                        Text(cast.subtitleSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(cast.serverError == nil ? Color.secondary : Color.red)
            }
            .padding(14)
        }
        .frame(minWidth: 520, minHeight: 440)
    }

    private var statusColor: Color {
        if case .failed = cast.phase { return .red }
        return .secondary
    }

    private var footer: String {
        if let error = cast.serverError { return error }
        let address = cast.lanAddress.map { "\($0):\(CastController.port)" } ?? "no local network"
        let ffmpeg = cast.ffmpegAvailable ? "ffmpeg ready" : "ffmpeg missing (needed for MP4/DASH and subtitle timing)"
        return "Serving on \(address) · \(ffmpeg)"
    }
}

/// Fallback for TVs that only accept screen mirroring: show the video full-screen on the TV display.
struct TVButtons: View {
    let cast: CastController
    @ObservedObject var display: TVDisplay

    var body: some View {
        HStack(spacing: 8) {
            if display.isShowing {
                Button("Close TV display", systemImage: "xmark.rectangle", action: display.hide)
            } else {
                Button(display.externalScreenName.map { "Show on \($0)" } ?? "Full screen",
                       systemImage: "tv", action: cast.showOnTVDisplay)
            }
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hint: String {
        if display.isShowing { return "Press Esc on it to close." }
        if display.externalScreenName != nil { return "Fallback if AirPlay doesn't show the video." }
        return "Fallback: mirror your screen to the TV (Control Center → Screen Mirroring), then use this."
    }
}

struct ExtensionBanner: View {
    @ObservedObject var status: SafariExtensionStatus

    var body: some View {
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
            Button("Open Safari Settings", action: status.openSafariSettings)
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
                    ? "Updates the app and its Safari extension, then reopens."
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
