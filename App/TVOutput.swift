import AppKit
import AVKit

/// Shows the player full-screen on a second display, such as a TV connected with
/// Screen Mirroring → "Use as Separate Display". Works with every AirPlay TV, because the Mac renders
/// the video (and its subtitles) and macOS streams the screen.
@MainActor
final class TVDisplay: ObservableObject {
    @Published private(set) var externalScreenName: String?
    @Published private(set) var isShowing = false

    private var window: NSWindow?
    private var screenObserver: NSObjectProtocol?

    init() {
        refreshScreens()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshScreens() }
        }
    }

    private var externalScreen: NSScreen? {
        NSScreen.screens.first { $0 != NSScreen.screens.first }
    }

    private func refreshScreens() {
        externalScreenName = externalScreen?.localizedName
        DebugLog.log("screens: \(NSScreen.screens.map(\.localizedName))")
        // The TV display went away (mirroring stopped); don't leave a window covering the Mac's screen.
        if isShowing, externalScreen == nil { hide() }
    }

    /// Fills the TV display, or this Mac's screen when it's being mirrored. Esc closes it.
    func show(_ player: AVPlayer) {
        hide()
        let screen = externalScreen ?? NSScreen.main ?? NSScreen.screens[0]
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect

        let window = TVWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.onClose = { [weak self] in self?.hide() }
        window.contentView = view
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary, .canJoinAllSpaces]
        window.setFrame(screen.frame, display: true)
        window.level = screen == NSScreen.screens.first ? .floating : .normal
        window.makeKeyAndOrderFront(nil)
        self.window = window
        isShowing = true
        DebugLog.log("TV display window on \(screen.localizedName)")
    }

    func hide() {
        window?.orderOut(nil)
        (window?.contentView as? AVPlayerView)?.player = nil
        window = nil
        isShowing = false
    }
}

private final class TVWindow: NSWindow {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?() } else { super.keyDown(with: event) }
    }
}
