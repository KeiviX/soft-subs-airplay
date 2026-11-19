//! Optional rewrite of each MPEG-TS segment's audio before the TV gets it.
//!
//! Samsung's AirPlay player (seen on a QN90BA) drops the sound of mono AAC streams on and off while the
//! picture keeps playing: audio for a while, silence, a few seconds of audio, longer silence. Removing the
//! stream's ID3 track didn't help; re-encoding the audio as stereo did. So mono sources are converted to
//! stereo, and everything else is passed through untouched.

use bytes::Bytes;
use std::time::Instant;

use crate::{ffmpeg, log};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AudioFix {
    /// Segments go to the TV as the host sent them.
    None,
    /// Keeps only the first video and audio streams, dropping ID3 and other data tracks. Lossless.
    Strip,
    /// Also re-encodes the audio as 48 kHz stereo AAC.
    Stereo,
}

impl AudioFix {
    pub fn name(self) -> &'static str {
        match self {
            AudioFix::None => "none",
            AudioFix::Strip => "strip",
            AudioFix::Stereo => "stereo",
        }
    }

    /// The mode for a new cast, given the source's audio channel count. `SOFTSUBS_AUDIO_FIX=none|strip|stereo`
    /// overrides it for testing.
    pub fn choose(audio_channels: Option<u32>) -> AudioFix {
        match std::env::var("SOFTSUBS_AUDIO_FIX").as_deref() {
            Ok("none") => AudioFix::None,
            Ok("strip") => AudioFix::Strip,
            Ok("stereo") => AudioFix::Stereo,
            _ if audio_channels == Some(1) => AudioFix::Stereo,
            _ => AudioFix::None,
        }
    }

    /// The rewritten segment, or the original if this mode leaves it alone or ffmpeg fails.
    pub async fn apply(self, segment: Bytes, name: &str) -> Bytes {
        if self == AudioFix::None {
            return segment;
        }
        let Some(program) = ffmpeg::tool("ffmpeg") else { return segment };
        let id = uuid::Uuid::new_v4();
        let folder = std::env::temp_dir();
        let input = folder.join(format!("softsubs-in-{id}.ts"));
        let output = folder.join(format!("softsubs-out-{id}.ts"));
        let result = async {
            tokio::fs::write(&input, &segment).await.ok()?;
            let mut arguments: Vec<String> = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-f", "mpegts", "-i"]
                .iter()
                .map(|s| s.to_string())
                .collect();
            arguments.push(input.to_string_lossy().into_owned());
            arguments.extend(["-map", "0:v:0", "-map", "0:a:0"].iter().map(|s| s.to_string()));
            let codecs: &[&str] = match self {
                AudioFix::Stereo => &["-c:v", "copy", "-c:a", "aac", "-ac", "2", "-ar", "48000", "-b:a", "192k"],
                _ => &["-c", "copy"],
            };
            arguments.extend(codecs.iter().map(|s| s.to_string()));
            // -copyts and zero mux delay keep the source timestamps, so segments still line up with each other.
            arguments.extend(["-copyts", "-muxdelay", "0", "-muxpreload", "0", "-f", "mpegts"].iter().map(|s| s.to_string()));
            arguments.push(output.to_string_lossy().into_owned());
            let started = Instant::now();
            let status = ffmpeg::run(&program, &arguments).await.ok()?;
            if !status.status.success() {
                return None;
            }
            let data = tokio::fs::read(&output).await.ok().filter(|data| !data.is_empty())?;
            log::log(format!(
                "audio fix {} {}B -> {}B in {}ms",
                self.name(),
                segment.len(),
                data.len(),
                started.elapsed().as_millis()
            ));
            Some(Bytes::from(data))
        }
        .await;
        let _ = tokio::fs::remove_file(&input).await;
        let _ = tokio::fs::remove_file(&output).await;
        result.unwrap_or_else(|| {
            log::problem(format!("audio fix {} failed for {name}; sending the segment unchanged", self.name()));
            segment
        })
    }
}
