import AppKit
import AVFoundation
import Foundation
import Network

/// What the browser extension sends to `POST /api/cast`.
struct CastRequest: Decodable {
    struct Subtitles: Decodable {
        var label: String?
        var language: String?
        var cues: [Cue]
    }

    var url: String
    var title: String?
    var headers: [String: String]?
    var startTime: Double?
    var duration: Double?
    var subtitles: Subtitles?
    var subtitlesOff: Bool?
    var preferredLanguage: String?
}

/// Owns the stream server and the AVPlayer that AirPlays the rebuilt stream to the TV.
@MainActor
final class CastController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing(String)
        case playing
        case failed(String)
    }

    static let port: UInt16 = 47800

    @Published private(set) var phase = Phase.idle
    @Published private(set) var title = ""
    @Published private(set) var isOnTV = false
    @Published private(set) var serverError: String?
    @Published private(set) var lanAddress = LANAddress.current()
    @Published private(set) var subtitleOffset = 0.0
    @Published private(set) var subtitleSummary = ""
    @Published private(set) var selectedSubtitleTrack: String?
    @Published var subtitlesOn = true {
        didSet { Task { await applySubtitleSelection() } }
    }

    let player = AVPlayer()
    let tvDisplay = TVDisplay()
    let chromeExtension = ChromeExtension()
    let ffmpegAvailable = FFmpeg.tool("ffmpeg") != nil && FFmpeg.tool("ffprobe") != nil

    private let store = SessionStore()
    private lazy var streams = StreamService(store: store)
    private var server: HTTPServer?
    private var sessionID: String?
    private var preferredLanguage = ""
    private var castTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var remuxProcess: Process?
    private var remuxFolder: URL?
    private var observations: [NSKeyValueObservation] = []
    /// The LAN address baked into the current item's URL, which the TV fetches every segment from.
    private var servedAddress: String?
    private let pathMonitor = NWPathMonitor()
    private var networkTask: Task<Void, Never>?

    init() {
        // Our selection must win over the user's system-wide caption preferences.
        player.appliesMediaSelectionCriteriaAutomatically = false
        player.allowsExternalPlayback = true
        observations.append(player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] player, _ in
            let active = player.isExternalPlaybackActive
            DebugLog.log("player externalPlaybackActive=\(active)")
            Task { @MainActor in self?.isOnTV = active }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { player, _ in
            DebugLog.log("player timeControlStatus=\(player.timeControlStatus.rawValue) waiting=\(player.reasonForWaitingToPlay?.rawValue ?? "-") rate=\(player.rate)")
        })
        let center = NotificationCenter.default
        center.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: nil, queue: nil) { note in
            guard let event = (note.object as? AVPlayerItem)?.errorLog()?.events.last else { return }
            DebugLog.log("AVPlayer error log \(event.errorStatusCode) \(event.errorDomain): \(event.errorComment ?? "") \(event.uri ?? "")")
        }
        center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: nil) { note in
            DebugLog.log("AVPlayer failed to play to end: \(String(describing: note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey]))")
        }
        center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: nil, queue: nil) { _ in
            DebugLog.log("AVPlayer playback stalled")
        }
        startServer()
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.networkChanged() }
        }
        pathMonitor.start(queue: .main)
    }

    var statusText: String {
        switch phase {
        case .idle: "Open a video in your browser and click the Soft Subs button."
        case .preparing(let message): message
        case .playing: isOnTV ? "Playing on your TV." : "Playing on this Mac. Click the AirPlay button in the video controls to send it to your TV."
        case .failed(let message): message
        }
    }

    // MARK: Server

    private func startServer() {
        let streams = self.streams
        do {
            let server = try HTTPServer(port: Self.port) { [weak self] request in
                guard request.path.hasPrefix("/api/") else { return await streams.handle(request) }
                guard let self else { return .error(503, "Shutting down") }
                return await self.handleAPI(request)
            }
            server.onFailure = { [weak self] message in
                Task { @MainActor in self?.serverError = message }
            }
            server.start()
            self.server = server
        } catch {
            serverError = "Couldn't start the server on port \(Self.port): \(error.localizedDescription)"
        }
    }

    /// The control API only answers this Mac, and only the extension or local tools (never a web page).
    private func handleAPI(_ request: HTTPRequest) async -> HTTPResponse {
        let host = request.header("host") ?? ""
        guard request.isLoopback, host.hasPrefix("127.0.0.1") || host.hasPrefix("localhost"),
              Self.isTrusted(origin: request.header("origin")) else {
            return .error(403, "Forbidden")
        }
        if let origin = request.header("origin"), !origin.hasPrefix("safari-web-extension://") { chromeExtension.markUsed() }
        switch (request.method, request.path) {
        case ("OPTIONS", _):
            return HTTPResponse(status: 204)
        case ("GET", "/api/status"):
            return .json([
                "ok": true,
                "platform": "mac",
                // A Chrome-based browser's extension reloads itself when this differs from its own version.
                "version": Updater.currentVersion,
                "phase": statusText,
                "playing": phase == .playing,
                "title": title,
                "onTV": isOnTV,
                "ffmpeg": ffmpegAvailable,
                "lanAddress": lanAddress as Any? ?? NSNull(),
                "subtitleTrack": selectedSubtitleTrack as Any? ?? NSNull(),
            ])
        case ("POST", "/api/cast"):
            do {
                DebugLog.saveLastCast(request.body)
                let cast = try JSONDecoder().decode(CastRequest.self, from: request.body)
                DebugLog.log("cast \(cast.url) subtitles=\(cast.subtitles?.cues.count ?? 0) headers=\(cast.headers?.keys.sorted() ?? [])")
                return .json(["ok": true, "session": startCast(cast)])
            } catch {
                return .error(400, "Invalid cast request: \(error.localizedDescription)")
            }
        case ("POST", "/api/stop"):
            stop()
            return .json(["ok": true])
        default:
            return .error(404, "Not found")
        }
    }

    private static func isTrusted(origin: String?) -> Bool {
        guard let origin else { return true }
        // webkit-extension:// is browsers built on WebKit's own extension support, such as Keivi.
        return ["safari-web-extension://", "chrome-extension://", "moz-extension://", "webkit-extension://"].contains { origin.hasPrefix($0) }
    }

    // MARK: Casting

    @discardableResult
    func startCast(_ request: CastRequest) -> String {
        stop()
        let id = UUID().uuidString.lowercased()
        sessionID = id
        _ = DebugLog.takeProblem()
        title = request.title ?? "Video"
        subtitleOffset = 0
        subtitlesOn = !(request.subtitlesOff ?? false)
        preferredLanguage = request.subtitles?.language ?? request.preferredLanguage ?? ""
        phase = .preparing("Loading the stream…")
        NSApp.activate()
        castTask = Task { await prepareAndPlay(id: id, request: request) }
        return id
    }

    // MARK: TV output

    /// Plays full-screen on the TV display (Screen Mirroring → Use as Separate Display).
    func showOnTVDisplay() {
        tvDisplay.show(player)
        player.play()
    }

    func stop() {
        tvDisplay.hide()
        castTask?.cancel()
        reloadTask?.cancel()
        networkTask?.cancel()
        servedAddress = nil
        remuxProcess?.terminate()
        remuxProcess = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let id = sessionID { store.remove(id) }
        if let folder = remuxFolder { try? FileManager.default.removeItem(at: folder) }
        remuxFolder = nil
        sessionID = nil
        title = ""
        subtitleSummary = ""
        selectedSubtitleTrack = nil
        phase = .idle
    }

    private func prepareAndPlay(id: String, request: CastRequest) async {
        do {
            guard let url = URL(string: request.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw CastError.badURL
            }
            let headers = request.headers ?? [:]
            let cues = (request.subtitles?.cues ?? []).filter { $0.end > $0.start }.sorted { $0.start < $1.start }
            var session = CastSession(id: id, source: .hls(url), headers: headers, cues: cues,
                                      subtitleLabel: request.subtitles?.label ?? "Subtitles",
                                      subtitleLanguage: request.subtitles?.language ?? "")

            if !(await MediaProbe.isHLS(url, headers: headers)) {
                guard ffmpegAvailable else { throw CastError.needsFFmpeg }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SoftSubs/\(id)")
                remuxFolder = folder
                let process = Process()
                remuxProcess = process
                phase = .preparing("Repackaging the video for AirPlay…")
                try await Remuxer.remux(url, headers: headers, into: folder, duration: request.duration, process: process) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.sessionID == id else { return }
                        self.phase = .preparing("Repackaging the video for AirPlay… \(Int(fraction * 100))%")
                    }
                }
                remuxProcess = nil
                session.source = .local(folder)
            }
            try Task.checkCancellation()

            phase = .preparing("Lining up the subtitles…")
            let probeURL = switch session.source {
            case .hls(let url): url
            case .local(let folder): folder.appendingPathComponent("index.m3u8")
            }
            let probe = await MediaProbe.probe(probeURL, headers: headers)
            session.duration = max(probe.duration, request.duration ?? 0)
            session.timestampBase = UInt64(max(0, probe.startTime ?? 0) * 90_000)
            session.audioFix = AudioFix.choose(audioChannels: probe.audioChannels)
            DebugLog.log("probe duration=\(probe.duration) start=\(probe.startTime.map { String($0) } ?? "unknown") audioChannels=\(probe.audioChannels.map { String($0) } ?? "unknown") audioFix=\(session.audioFix.rawValue) cues=\(cues.count)")
            try Task.checkCancellation()

            store.put(session)
            subtitleSummary = cues.isEmpty
                ? (subtitlesOn ? "Using the stream's own subtitles, if it has any." : "Subtitles off.")
                : "\(session.subtitleLabel): \(cues.count) lines" + (probe.startTime == nil ? " (start time unknown, use the offset if they're out of sync)" : "")

            try await load(session, at: request.startTime.map { CMTime(seconds: $0, preferredTimescale: 600) })
            player.play()
            phase = .playing
        } catch is CancellationError {
        } catch {
            DebugLog.log("cast failed: \(error.localizedDescription)")
            if sessionID == id { phase = .failed(Self.failureMessage(error)) }
        }
    }

    private func load(_ session: CastSession, at time: CMTime?) async throws {
        lanAddress = LANAddress.current()
        guard let address = lanAddress else { throw CastError.noNetwork }
        let url = URL(string: "http://\(address):\(Self.port)\(session.pathPrefix)/master.m3u8?v=\(session.version)")!
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        servedAddress = address

        for _ in 0..<150 where item.status == .unknown {
            try await Task.sleep(for: .milliseconds(200))
        }
        if item.status != .readyToPlay {
            var reason = item.error?.localizedDescription ?? "the stream didn't load in time"
            if let event = item.errorLog()?.events.last {
                DebugLog.log("AVPlayer error \(event.errorStatusCode) \(event.errorDomain): \(event.errorComment ?? "") \(event.uri ?? "")")
            }
            if let problem = DebugLog.takeProblem() { reason += " (\(problem))" }
            throw CastError.playbackFailed(reason)
        }
        await applySubtitleSelection()
        if let time, time.seconds > 1 {
            await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func applySubtitleSelection() async {
        guard let item = player.currentItem,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
        guard subtitlesOn else {
            item.select(nil, in: group)
            selectedSubtitleTrack = nil
            return
        }
        let session = sessionID.flatMap { store[$0] }
        let options = group.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
        let language = preferredLanguage.lowercased()
        let choice = options.first { session?.cues.isEmpty == false && $0.displayName == session?.subtitleLabel }
            ?? options.first { !language.isEmpty && ($0.extendedLanguageTag ?? "").lowercased().hasPrefix(language) }
            ?? options.first
        item.select(choice, in: group)
        selectedSubtitleTrack = choice?.displayName
    }

    // MARK: Subtitle timing

    /// Positive values show subtitles later. The change is applied by reloading the item at the same position.
    func nudgeSubtitles(by delta: Double) {
        guard let id = sessionID, phase == .playing else { return }
        subtitleOffset = ((subtitleOffset + delta) * 100).rounded() / 100
        let offset = subtitleOffset
        store.update(id) {
            $0.subtitleOffset = offset
            $0.version += 1
        }
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await reload(id)
        }
    }

    /// Reloads the current item at the same position. The AirPlay route survives the swap, so the TV
    /// just picks up the new URL.
    private func reload(_ id: String, attempts: Int = 1) async {
        guard sessionID == id, let session = store[id] else { return }
        let time = player.currentTime()
        let wasPlaying = player.rate > 0
        for attempt in 1...attempts {
            do {
                try await load(session, at: time)
                if wasPlaying { player.play() }
                return
            } catch is CancellationError {
                return
            } catch {
                guard attempt < attempts, sessionID == id else {
                    phase = .failed(Self.failureMessage(error))
                    return
                }
                DebugLog.log("reload attempt \(attempt) failed: \(error.localizedDescription); trying again")
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: Network changes

    /// When Wi-Fi reconnects, DHCP can hand this Mac a different address. The TV keeps fetching segments
    /// from the old one, plays out its buffer and then goes silent, so point it at the new address.
    private func networkChanged() {
        networkTask?.cancel()
        networkTask = Task {
            // Path updates come in bursts while an interface comes up; let the address settle.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let address = LANAddress.current()
            lanAddress = address
            guard phase == .playing, let id = sessionID, let address, let old = servedAddress, address != old else { return }
            DebugLog.log("LAN address changed \(old) -> \(address); reloading the stream for the TV")
            reloadTask?.cancel()
            // macOS rebuilds the AirPlay connection on the new network too, which can take longer than one load.
            reloadTask = Task { await reload(id, attempts: 3) }
        }
    }

    /// What the person sees when a cast fails: the reason, then a nudge toward another stream.
    private static func failureMessage(_ error: Error) -> String {
        let reason = error.localizedDescription.trimmingCharacters(in: .whitespaces)
        let ended = reason.last.map { ".!?)".contains($0) } ?? true
        return reason + (ended ? "" : ".") + " Let's try a different source."
    }
}
