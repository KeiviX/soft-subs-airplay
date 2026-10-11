import Foundation

struct Cue: Codable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

/// Turns a list of cues into an HLS subtitle rendition: a VOD playlist of fixed-length WebVTT segments.
enum WebVTT {
    static let segmentLength = 60.0

    static func playlist(duration: Double, uri: (Int) -> String) -> String {
        let count = max(1, Int((duration / segmentLength).rounded(.up)))
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:\(Int(segmentLength))",
                     "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD"]
        for index in 0..<count {
            let length = min(segmentLength, duration - Double(index) * segmentLength)
            lines.append(String(format: "#EXTINF:%.3f,", max(length, 0.001)))
            lines.append(uri(index))
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// One segment's cues. `timestampBase` is the media's first presentation timestamp (90 kHz), which is
    /// what the browser's `currentTime == 0` corresponds to, so cue times line up with the video.
    /// Cues that straddle a boundary appear in both segments; players de-duplicate them.
    static func segment(_ index: Int, cues: [Cue], offset: Double, timestampBase: UInt64) -> String {
        let start = Double(index) * segmentLength
        let end = start + segmentLength
        var output = "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:\(timestampBase),LOCAL:00:00:00.000\n"
        for cue in cues {
            let cueStart = max(0, cue.start + offset)
            let cueEnd = cue.end + offset
            let text = sanitize(cue.text)
            guard cueEnd > cueStart, cueEnd > start, cueStart < end, !text.isEmpty else { continue }
            output += "\n\(timestamp(cueStart)) --> \(timestamp(cueEnd))\n\(text)\n"
        }
        return output
    }

    static func timestamp(_ seconds: Double) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// Keeps cue text valid WebVTT: no blank lines (they end a cue) and no stray arrows.
    private static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: "-->", with: "→")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
