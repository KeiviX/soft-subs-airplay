import Foundation

/// Writes a plain-text log to ~/Library/Logs/SoftSubs so failed casts can be diagnosed afterwards.
enum DebugLog {
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SoftSubs")
    private static let file = folder.appendingPathComponent("soft-subs.log")
    private static let queue = DispatchQueue(label: "softsubs.log")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastProblem: String?

    static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: file)
            }
        }
    }

    /// Remembers the most recent upstream failure so it can be shown next to AVPlayer's vaguer error.
    static func problem(_ message: String) {
        log("PROBLEM \(message)")
        lock.withLock { lastProblem = message }
    }

    static func takeProblem() -> String? {
        lock.withLock {
            defer { lastProblem = nil }
            return lastProblem
        }
    }

    /// Keeps the last cast request (it includes the page's cookies) so it can be replayed with scripts/replay-last-cast.sh.
    static func saveLastCast(_ body: Data) {
        queue.async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? body.write(to: folder.appendingPathComponent("last-cast.json"))
        }
    }
}

/// Some sites disguise HLS segments as images: fake PNG/JPEG bytes in front of the real MPEG-TS data.
/// Browsers' hls.js tolerates that; AVPlayer and the TV don't, so strip the prefix.
enum SegmentSniffer {
    static func unwrap(_ data: Data) -> (data: Data, contentType: String)? {
        let bytes = [UInt8](data.prefix(64 * 1024))
        guard bytes.count > 188 * 3 else { return nil }
        if isTS(bytes, at: 0) { return nil }
        if bytes.count > 8, String(decoding: bytes[4..<8], as: UTF8.self).range(of: "^(ftyp|styp|moof|sidx)$", options: .regularExpression) != nil {
            return nil
        }
        for offset in 1..<(bytes.count - 188 * 2) where isTS(bytes, at: offset) {
            return (data.subdata(in: (data.startIndex + offset)..<data.endIndex), "video/mp2t")
        }
        return nil
    }

    private static func isTS(_ bytes: [UInt8], at offset: Int) -> Bool {
        offset + 376 < bytes.count && bytes[offset] == 0x47 && bytes[offset + 188] == 0x47 && bytes[offset + 376] == 0x47
    }
}
