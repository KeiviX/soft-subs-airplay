import Foundation

enum CastError: LocalizedError {
    case badURL
    case upstream(Int, String)
    case needsFFmpeg
    case remuxFailed(String)
    case noNetwork
    case playbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .badURL: "The page didn't give a usable video URL."
        case .upstream(let status, let host): "\(host) refused the request (HTTP \(status))."
        case .needsFFmpeg: "This video isn't HLS, so it needs ffmpeg to repackage it. Run: brew install ffmpeg"
        case .remuxFailed(let message): "ffmpeg couldn't repackage the video: \(message)"
        case .noNetwork: "This Mac isn't on a local network, so the TV can't reach it."
        case .playbackFailed(let message): "Playback failed: \(message)"
        }
    }
}

enum FFmpeg {
    static func tool(_ name: String) -> URL? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Runs `process` (already pointed at a tool) and collects its output.
    static func run(_ process: Process, onOutput: (@Sendable (String) -> Void)? = nil) async throws -> (status: Int32, output: String, errors: String) {
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let collected = LockedData()
        let collectedErrors = LockedData()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            collected.append(data)
            onOutput?(String(decoding: data, as: UTF8.self))
        }
        errors.fileHandleForReading.readabilityHandler = { collectedErrors.append($0.availableData) }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                collected.append(output.fileHandleForReading.readDataToEndOfFile())
                collectedErrors.append(errors.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: (process.terminationStatus, collected.string, collectedErrors.string))
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

private extension Dictionary where Key == String, Value == String {
    func with(range: String?) -> Self {
        var copy = self
        copy["Range"] = range
        return copy
    }
}

private final class LockedData: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ more: Data) { lock.withLock { data.append(more) } }
    var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

enum MediaProbe {
    struct Result {
        var duration = 0.0
        /// The first segment's presentation time in seconds, or nil when it couldn't be measured.
        var startTime: Double?
    }

    static func isHLS(_ url: URL, headers: [String: String]) async -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["m3u8", "m3u"].contains(ext) { return true }
        if ["mp4", "m4v", "mov", "mpd", "webm", "mkv", "ts"].contains(ext) { return false }
        var headers = headers
        headers["Range"] = "bytes=0-63"
        guard let (data, response) = try? await Upstream.request(url, headers: headers) else { return false }
        return Playlist.looksLikePlaylist(data, contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "", url: response.url ?? url)
    }

    /// Follows the first variant to a media playlist, sums its duration and measures where its first segment starts.
    static func probe(_ url: URL, headers: [String: String]) async -> Result {
        do {
            var (data, base) = try await Upstream.load(url, headers: headers)
            var text = String(decoding: data, as: UTF8.self)
            if Playlist.isMaster(text), let variant = Playlist.firstVariant(in: text, base: base) {
                (data, base) = try await Upstream.load(variant, headers: headers)
                text = String(decoding: data, as: UTF8.self)
            }
            var result = Result(duration: Playlist.totalDuration(text))
            // Encrypted segments can't be probed without decrypting them; fall back to 0.
            if text.contains("METHOD=AES-128") || text.contains("METHOD=SAMPLE-AES") { return result }
            guard let segment = Playlist.firstSegment(in: text, base: base) else { return result }
            var media = Data()
            if let initSection = Playlist.initSection(in: text, base: base) {
                media += try await Upstream.load(initSection.url, headers: headers.with(range: initSection.range)).0
            }
            media += try await Upstream.load(segment, headers: headers.with(range: Playlist.firstSegmentRange(in: text))).0
            result.startTime = await startTime(of: media, fileExtension: segment.pathExtension)
            return result
        } catch {
            return Result()
        }
    }

    private static func startTime(of media: Data, fileExtension: String) async -> Double? {
        guard let ffprobe = FFmpeg.tool("ffprobe") else { return nil }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("softsubs-probe-\(UUID().uuidString).\(fileExtension.isEmpty ? "ts" : fileExtension)")
        guard (try? media.write(to: file)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }

        let process = Process()
        process.executableURL = ffprobe
        process.arguments = ["-v", "error", "-show_entries", "format=start_time", "-of", "default=nw=1:nk=1", file.path]
        guard let result = try? await FFmpeg.run(process), result.status == 0 else { return nil }
        return Double(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum Remuxer {
    /// Repackages a non-HLS source (MP4, DASH...) into fMP4 HLS without re-encoding.
    static func remux(_ url: URL, headers: [String: String], into folder: URL, duration: Double?,
                      process: Process, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let ffmpeg = FFmpeg.tool("ffmpeg") else { throw CastError.needsFFmpeg }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-progress", "pipe:1"]
        if let userAgent = headers["User-Agent"] { arguments += ["-user_agent", userAgent] }
        let extraHeaders = headers.filter { $0.key != "User-Agent" }.map { "\($0.key): \($0.value)\r\n" }.joined()
        if !extraHeaders.isEmpty { arguments += ["-headers", extraHeaders] }
        arguments += [
            "-i", url.absoluteString,
            "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy",
            "-f", "hls", "-hls_time", "6", "-hls_playlist_type", "vod",
            "-hls_segment_type", "fmp4", "-hls_fmp4_init_filename", "init.mp4",
            "-hls_segment_filename", folder.appendingPathComponent("seg%05d.m4s").path,
            folder.appendingPathComponent("index.m3u8").path,
        ]
        process.executableURL = ffmpeg
        process.arguments = arguments

        let result = try await FFmpeg.run(process) { chunk in
            guard let duration, duration > 0 else { return }
            for line in chunk.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                if let micros = Double(line.dropFirst(12)) { progress(min(1, micros / 1_000_000 / duration)) }
            }
        }
        guard result.status == 0 else {
            let message = result.errors.split(separator: "\n").last.map(String.init) ?? "exit code \(result.status)"
            throw CastError.remuxFailed(message)
        }
    }
}

enum LANAddress {
    /// The Mac's IPv4 address on Wi-Fi/Ethernet, which the TV uses to reach the stream server.
    static func current() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }

        var candidates: [(interface: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard let address = pointer.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            candidates.append((String(cString: pointer.pointee.ifa_name), text))
        }
        return candidates.first { $0.interface.hasPrefix("en") }?.address ?? candidates.first?.address
    }
}
