import Foundation

struct CastSession {
    enum Source {
        /// A remote HLS stream, proxied segment by segment.
        case hls(URL)
        /// A folder holding our ffmpeg remux (`index.m3u8` plus fMP4 segments).
        case local(URL)
    }

    let id: String
    var source: Source
    /// Sent with every upstream request (Referer, Cookie, User-Agent...), since the TV has none of the browser's.
    var headers: [String: String]
    var cues: [Cue]
    var subtitleLabel: String
    var subtitleLanguage: String
    var subtitleOffset = 0.0
    var timestampBase: UInt64 = 0
    var duration = 0.0
    var version = 0

    var pathPrefix: String { "/s/\(id)" }
    var subtitleMedia: String? {
        cues.isEmpty ? nil : Playlist.subtitleMedia(name: subtitleLabel, language: subtitleLanguage,
                                                    uri: "\(pathPrefix)/subs.m3u8?v=\(version)")
    }
}

final class SessionStore: @unchecked Sendable {
    private var sessions: [String: CastSession] = [:]
    private let lock = NSLock()

    subscript(id: String) -> CastSession? { lock.withLock { sessions[id] } }
    func put(_ session: CastSession) { lock.withLock { sessions[session.id] = session } }
    func remove(_ id: String) { lock.withLock { _ = sessions.removeValue(forKey: id) } }

    func update(_ id: String, _ change: (inout CastSession) -> Void) {
        lock.withLock {
            guard var session = sessions[id] else { return }
            change(&session)
            sessions[id] = session
        }
    }
}

enum Upstream {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    static func request(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// Loads an http(s) URL, throwing on non-2xx, or reads a file URL. Returns the final URL after redirects.
    static func load(_ url: URL, headers: [String: String]) async throws -> (Data, URL) {
        if url.isFileURL { return (try Data(contentsOf: url), url) }
        let (data, response) = try await request(url, headers: headers)
        guard (200..<300).contains(response.statusCode) else {
            throw CastError.upstream(response.statusCode, url.host ?? url.absoluteString)
        }
        return (data, response.url ?? url)
    }
}

/// Serves everything under `/s/<session>/` to AVPlayer and the TV.
final class StreamService: @unchecked Sendable {
    private let store: SessionStore

    init(store: SessionStore) { self.store = store }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let parts = request.path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "s", let session = store[parts[1]] else {
            return .error(404, "Unknown session")
        }
        let rest = parts[2...].joined(separator: "/")
        DebugLog.log("\(request.isLoopback ? "local" : "lan  ") \(request.method) \(rest.prefix(60))")

        switch rest {
        case "master.m3u8":
            return await master(session)
        case "subs.m3u8":
            let duration = max(session.duration, (session.cues.map(\.end).max() ?? 0) + session.subtitleOffset, 1)
            return playlist(WebVTT.playlist(duration: duration) { "\(session.pathPrefix)/subs/\($0).vtt?v=\(session.version)" })
        case "p":
            return await proxy(session, request)
        default:
            if rest.hasPrefix("subs/"), let index = Int(rest.dropFirst(5).replacingOccurrences(of: ".vtt", with: "")) {
                let body = WebVTT.segment(index, cues: session.cues, offset: session.subtitleOffset, timestampBase: session.timestampBase)
                return .text(body, contentType: "text/vtt; charset=utf-8")
            }
            if rest.hasPrefix("local/"), case .local(let folder) = session.source {
                return serveFile(named: String(rest.dropFirst(6)), in: folder)
            }
            return .error(404, "Not found")
        }
    }

    private func master(_ session: CastSession) async -> HTTPResponse {
        switch session.source {
        case .local:
            return playlist(Playlist.syntheticMaster(mediaURI: "\(session.pathPrefix)/local/index.m3u8", subtitles: session.subtitleMedia))
        case .hls(let url):
            do {
                let (data, finalURL) = try await Upstream.load(url, headers: session.headers)
                let text = String(decoding: data, as: UTF8.self)
                guard Playlist.isMaster(text) else {
                    return playlist(Playlist.syntheticMaster(mediaURI: proxyPath(session, finalURL), subtitles: session.subtitleMedia))
                }
                let proxied = Playlist.rewrite(text, base: finalURL) { self.proxyPath(session, $0) }
                // With no cues of our own, keep whatever subtitles the stream already carries.
                return playlist(session.cues.isEmpty ? proxied : Playlist.replacingSubtitles(in: proxied, with: session.subtitleMedia))
            } catch {
                DebugLog.problem("master playlist \(url.host ?? ""): \(error.localizedDescription)")
                return .error(502, error.localizedDescription)
            }
        }
    }

    private func proxy(_ session: CastSession, _ request: HTTPRequest) async -> HTTPResponse {
        guard let raw = request.query["u"], let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return .error(400, "Bad URL")
        }
        var headers = session.headers
        if let range = request.header("range") { headers["Range"] = range }

        do {
            let (data, response) = try await Upstream.request(url, headers: headers)
            let finalURL = response.url ?? url
            let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
            let name = "\(finalURL.host ?? "")/…/\(finalURL.lastPathComponent)"
            DebugLog.log("upstream \(response.statusCode) \(contentType) \(data.count)B \(name)")
            guard (200..<300).contains(response.statusCode) else {
                DebugLog.problem("\(finalURL.host ?? "the video host") returned HTTP \(response.statusCode) for \(finalURL.lastPathComponent)")
                return HTTPResponse(status: response.statusCode, body: data)
            }
            if Playlist.looksLikePlaylist(data, contentType: contentType, url: finalURL) {
                let text = String(decoding: data, as: UTF8.self)
                return playlist(Playlist.rewrite(text, base: finalURL) { self.proxyPath(session, $0) })
            }
            if let unwrapped = SegmentSniffer.unwrap(data) {
                DebugLog.log("unwrapped disguised segment (\(data.count - unwrapped.data.count)B prefix) \(name)")
                return HTTPResponse(status: 200, headers: ["Content-Type": unwrapped.contentType], body: unwrapped.data)
            }
            var output = HTTPResponse(status: response.statusCode, body: data)
            for name in ["Content-Type", "Content-Range", "Accept-Ranges"] {
                if let value = response.value(forHTTPHeaderField: name) { output.headers[name] = value }
            }
            return output
        } catch {
            DebugLog.problem("\(url.host ?? "the video host"): \(error.localizedDescription)")
            return .error(502, error.localizedDescription)
        }
    }

    private func serveFile(named name: String, in folder: URL) -> HTTPResponse {
        let file = folder.appendingPathComponent(name).standardizedFileURL
        guard file.path.hasPrefix(folder.standardizedFileURL.path + "/"), let data = try? Data(contentsOf: file) else {
            return .error(404, "Not found")
        }
        let type = switch file.pathExtension {
        case "m3u8": Playlist.mimeType
        case "m4s", "mp4": "video/mp4"
        default: "application/octet-stream"
        }
        return HTTPResponse(status: 200, headers: ["Content-Type": type], body: data)
    }

    private func proxyPath(_ session: CastSession, _ url: URL) -> String {
        "\(session.pathPrefix)/p?u=" + url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlStrictValue)!
    }

    private func playlist(_ text: String) -> HTTPResponse {
        .text(text, contentType: Playlist.mimeType)
    }
}

private extension CharacterSet {
    static let urlStrictValue = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
}
