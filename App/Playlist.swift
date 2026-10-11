import Foundation

/// HLS playlist helpers: routing every URI through the local proxy and swapping in our subtitle track.
enum Playlist {
    static let mimeType = "application/vnd.apple.mpegurl"
    static let subtitleGroup = "softsubs"

    static func isMaster(_ text: String) -> Bool { text.contains("#EXT-X-STREAM-INF") }

    static func looksLikePlaylist(_ data: Data, contentType: String, url: URL) -> Bool {
        if contentType.lowercased().contains("mpegurl") { return true }
        if ["m3u8", "m3u"].contains(url.pathExtension.lowercased()) { return true }
        let start = String(decoding: data.prefix(16), as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}").union(.whitespacesAndNewlines))
        return start.hasPrefix("#EXTM3U")
    }

    static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    /// Resolves a playlist reference against the playlist's own URL (works for http and file URLs).
    static func absolute(_ reference: String, base: URL) -> URL? {
        URL(string: reference, relativeTo: base)?.absoluteURL
    }

    // MARK: Rewriting

    /// Rewrites every segment, playlist and key URI so the TV fetches it through `proxy`.
    static func rewrite(_ text: String, base: URL, proxy: (URL) -> String) -> String {
        lines(text).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return trimmed }
            if trimmed.hasPrefix("#") { return rewriteURIAttributes(in: trimmed, base: base, proxy: proxy) }
            return proxiable(trimmed, base: base).map(proxy) ?? trimmed
        }.joined(separator: "\n")
    }

    private static let uriAttribute = try! NSRegularExpression(pattern: #"URI="([^"]*)""#)

    private static func rewriteURIAttributes(in line: String, base: URL, proxy: (URL) -> String) -> String {
        guard line.contains("URI=\"") else { return line }
        var result = line as NSString
        let matches = uriAttribute.matches(in: line, range: NSRange(location: 0, length: result.length))
        // Replace from the end so earlier ranges stay valid. FairPlay (skd://) and data: URIs are left alone.
        for match in matches.reversed() {
            let value = result.substring(with: match.range(at: 1))
            guard let url = proxiable(value, base: base) else { continue }
            result = result.replacingCharacters(in: match.range(at: 1), with: proxy(url)) as NSString
        }
        return result as String
    }

    private static func proxiable(_ reference: String, base: URL) -> URL? {
        guard let url = absolute(reference, base: base), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    // MARK: Subtitles

    static func subtitleMedia(name: String, language: String, uri: String) -> String {
        let name = name.replacingOccurrences(of: "\"", with: "'")
        let language = languageTag(language) ?? languageTag(name) ?? "und"
        return "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"\(subtitleGroup)\",NAME=\"\(name)\",LANGUAGE=\"\(language)\","
            + "DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,URI=\"\(uri)\""
    }

    /// A BCP 47 tag for values like "en", "pt-BR", "English" or "CR English", so the TV can name the track.
    static func languageTag(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil { return trimmed }
        let english = Locale(identifier: "en")
        let words = Set(trimmed.lowercased().split { !$0.isLetter }.map(String.init))
        return Locale.LanguageCode.isoLanguageCodes.first { code in
            code.identifier.count == 2 && english.localizedString(forLanguageCode: code.identifier).map { words.contains($0.lowercased()) } == true
        }?.identifier
    }

    /// Removes the stream's own subtitle renditions and points every variant at `media` instead.
    static func replacingSubtitles(in master: String, with media: String?) -> String {
        var output: [String] = []
        for line in lines(master) {
            if line.hasPrefix("#EXT-X-MEDIA:"),
               attributes(String(line.dropFirst(13))).contains(where: { $0.key == "TYPE" && $0.value == "SUBTITLES" }) {
                continue
            }
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                var attrs = attributes(String(line.dropFirst(18))).filter { $0.key != "SUBTITLES" }
                if media != nil { attrs.append((key: "SUBTITLES", value: "\"\(subtitleGroup)\"")) }
                output.append("#EXT-X-STREAM-INF:" + attrs.map { "\($0.key)=\($0.value)" }.joined(separator: ","))
                continue
            }
            output.append(line)
            if line.hasPrefix("#EXTM3U"), let media { output.append(media) }
        }
        return output.joined(separator: "\n")
    }

    /// A master playlist for a source that only has a single media playlist (or our own remux).
    static func syntheticMaster(mediaURI: String, subtitles media: String?) -> String {
        var output = ["#EXTM3U"]
        if let media { output.append(media) }
        output.append("#EXT-X-STREAM-INF:BANDWIDTH=5000000" + (media != nil ? ",SUBTITLES=\"\(subtitleGroup)\"" : ""))
        output.append(mediaURI)
        return output.joined(separator: "\n") + "\n"
    }

    /// Splits an attribute list such as `BANDWIDTH=1,CODECS="a,b"` into ordered key/value pairs.
    static func attributes(_ list: String) -> [(key: String, value: String)] {
        var pairs: [(key: String, value: String)] = []
        var current = ""
        var inQuotes = false
        func flush() {
            guard let equals = current.firstIndex(of: "=") else { return }
            pairs.append((key: String(current[..<equals]), value: String(current[current.index(after: equals)...])))
        }
        for character in list {
            if character == "\"" { inQuotes.toggle() }
            if character == ",", !inQuotes {
                flush()
                current = ""
            } else {
                current.append(character)
            }
        }
        flush()
        return pairs
    }

    // MARK: Inspection

    static func firstVariant(in master: String, base: URL) -> URL? {
        let all = lines(master)
        guard let index = all.firstIndex(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) else { return nil }
        let uri = all[(index + 1)...].first { !$0.isEmpty && !$0.hasPrefix("#") }
        return uri.flatMap { absolute($0.trimmingCharacters(in: .whitespaces), base: base) }
    }

    static func firstSegment(in media: String, base: URL) -> URL? {
        lines(media).first { !$0.isEmpty && !$0.hasPrefix("#") }
            .flatMap { absolute($0.trimmingCharacters(in: .whitespaces), base: base) }
    }

    /// The init section's URL and its `Range` header value, if it's a byte range.
    static func initSection(in media: String, base: URL) -> (url: URL, range: String?)? {
        guard let line = lines(media).first(where: { $0.hasPrefix("#EXT-X-MAP:") }) else { return nil }
        let attrs = attributes(String(line.dropFirst(11)))
        let unquote = { (value: String) in value.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        guard let uri = attrs.first(where: { $0.key == "URI" })?.value,
              let url = absolute(unquote(uri), base: base) else { return nil }
        return (url, attrs.first { $0.key == "BYTERANGE" }.flatMap { rangeHeader(unquote($0.value)) })
    }

    /// The `Range` header for the first segment when the playlist uses `#EXT-X-BYTERANGE`.
    static func firstSegmentRange(in media: String) -> String? {
        var range: String?
        for line in lines(media) {
            if line.hasPrefix("#EXT-X-BYTERANGE:") { range = rangeHeader(String(line.dropFirst(17))) }
            if !line.isEmpty, !line.hasPrefix("#") { break }
        }
        return range
    }

    /// Converts an HLS byte range (`length@offset`) into an HTTP `Range` value.
    private static func rangeHeader(_ value: String) -> String? {
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: "@")
        guard let length = Int(parts[0]), length > 0 else { return nil }
        let offset = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return "bytes=\(offset)-\(offset + length - 1)"
    }

    static func totalDuration(_ media: String) -> Double {
        lines(media).reduce(0) { total, line in
            guard line.hasPrefix("#EXTINF:") else { return total }
            return total + (Double(line.dropFirst(8).prefix { $0 != "," }.trimmingCharacters(in: .whitespaces)) ?? 0)
        }
    }
}
