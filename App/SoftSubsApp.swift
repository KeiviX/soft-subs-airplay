import AppKit
import AVKit
import SwiftUI

@main
struct SoftSubsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var cast = CastController()

    var body: some Scene {
        Window("Soft Subs", id: "main") {
            ContentView()
                .environmentObject(cast)
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

    var body: some View {
        VStack(spacing: 0) {
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
                    RoutePicker(player: cast.player)
                        .frame(width: 30, height: 30)
                        .help("Choose a TV")
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
                    HStack(spacing: 8) {
                        Toggle("Subtitles", isOn: $cast.subtitlesOn)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        Spacer()
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

struct RoutePicker: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
}
