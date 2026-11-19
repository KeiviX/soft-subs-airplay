import Foundation

/// Optional rewrite of each MPEG-TS segment's audio before the TV gets it.
///
/// Samsung's AirPlay player (seen on a QN90BA) drops the sound of mono AAC streams on and off while the
/// picture keeps playing: audio for a while, silence, a few seconds of audio, longer silence. Removing the
/// stream's ID3 track didn't help; re-encoding the audio as stereo did. So mono sources are converted to
/// stereo, and everything else is passed through untouched.
///
/// `defaults write com.keivi.softsubs AudioFix none|strip|stereo` overrides the choice for testing.
enum AudioFix: String {
    /// Segments go to the TV as the host sent them.
    case none
    /// Keeps only the first video and audio streams, dropping ID3 and other data tracks. Lossless.
    case strip
    /// Also re-encodes the audio as 48 kHz stereo AAC.
    case stereo

    /// The mode for a new cast, given the source's audio channel count (nil if it couldn't be measured).
    static func choose(audioChannels: Int?) -> AudioFix {
        if let override = UserDefaults.standard.string(forKey: "AudioFix").flatMap(AudioFix.init(rawValue:)) {
            return override
        }
        return audioChannels == 1 ? .stereo : .none
    }

    /// The rewritten segment, or the original if this mode leaves it alone or ffmpeg fails.
    func apply(to segment: Data, name: String) async -> Data {
        guard self != .none, let ffmpeg = FFmpeg.tool("ffmpeg") else { return segment }
        let folder = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        let input = folder.appendingPathComponent("softsubs-in-\(id).ts")
        let output = folder.appendingPathComponent("softsubs-out-\(id).ts")
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }
        guard (try? segment.write(to: input)) != nil else { return segment }

        let codecs = self == .stereo ? ["-c:v", "copy", "-c:a", "aac", "-ac", "2", "-ar", "48000", "-b:a", "192k"] : ["-c", "copy"]
        let process = Process()
        process.executableURL = ffmpeg
        // -copyts and zero mux delay keep the source timestamps, so segments still line up with each other.
        process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-f", "mpegts", "-i", input.path,
                             "-map", "0:v:0", "-map", "0:a:0"] + codecs
            + ["-copyts", "-muxdelay", "0", "-muxpreload", "0", "-f", "mpegts", output.path]
        let started = Date()
        guard let result = try? await FFmpeg.run(process), result.status == 0,
              let data = try? Data(contentsOf: output), !data.isEmpty else {
            DebugLog.problem("audio fix \(rawValue) failed for \(name); sending the segment unchanged")
            return segment
        }
        DebugLog.log("audio fix \(rawValue) \(segment.count)B -> \(data.count)B in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        return data
    }
}
