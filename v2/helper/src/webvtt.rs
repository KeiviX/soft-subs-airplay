//! Turns a list of cues into an HLS subtitle rendition: a VOD playlist of fixed-length WebVTT segments.

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Cue {
    pub start: f64,
    pub end: f64,
    pub text: String,
}

pub const SEGMENT_LENGTH: f64 = 60.0;

pub fn playlist(duration: f64, uri: impl Fn(usize) -> String) -> String {
    let count = ((duration / SEGMENT_LENGTH).ceil() as usize).max(1);
    let mut lines = vec![
        "#EXTM3U".to_string(),
        "#EXT-X-VERSION:3".to_string(),
        format!("#EXT-X-TARGETDURATION:{}", SEGMENT_LENGTH as u64),
        "#EXT-X-MEDIA-SEQUENCE:0".to_string(),
        "#EXT-X-PLAYLIST-TYPE:VOD".to_string(),
    ];
    for index in 0..count {
        let length = SEGMENT_LENGTH.min(duration - index as f64 * SEGMENT_LENGTH);
        lines.push(format!("#EXTINF:{:.3},", length.max(0.001)));
        lines.push(uri(index));
    }
    lines.push("#EXT-X-ENDLIST".to_string());
    lines.join("\n") + "\n"
}

/// One segment's cues. `timestamp_base` is the media's first presentation timestamp (90 kHz), which is
/// what the browser's `currentTime == 0` corresponds to, so cue times line up with the video.
/// Cues that straddle a boundary appear in both segments; players de-duplicate them.
pub fn segment(index: usize, cues: &[Cue], offset: f64, timestamp_base: u64) -> String {
    let start = index as f64 * SEGMENT_LENGTH;
    let end = start + SEGMENT_LENGTH;
    let mut output = format!("WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:{timestamp_base},LOCAL:00:00:00.000\n");
    for cue in cues {
        let cue_start = (cue.start + offset).max(0.0);
        let cue_end = cue.end + offset;
        let text = sanitize(&cue.text);
        if cue_end > cue_start && cue_end > start && cue_start < end && !text.is_empty() {
            output += &format!("\n{} --> {}\n{}\n", timestamp(cue_start), timestamp(cue_end), text);
        }
    }
    output
}

pub fn timestamp(seconds: f64) -> String {
    let ms = (seconds * 1000.0).round() as u64;
    format!("{:02}:{:02}:{:02}.{:03}", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
}

/// Keeps cue text valid WebVTT: no blank lines (they end a cue) and no stray arrows.
fn sanitize(text: &str) -> String {
    text.replace("-->", "→")
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn segments_cover_duration() {
        let text = playlist(125.0, |i| format!("subs/{i}.vtt"));
        assert_eq!(text.matches("#EXTINF").count(), 3);
        assert!(text.contains("#EXTINF:5.000,"));
    }

    #[test]
    fn cues_land_in_their_segment() {
        let cues = vec![
            Cue { start: 1.0, end: 2.5, text: "Hello\n\nthere".into() },
            Cue { start: 61.0, end: 62.0, text: "Later".into() },
        ];
        let first = segment(0, &cues, 0.0, 9000);
        assert!(first.contains("MPEGTS:9000"));
        assert!(first.contains("00:00:01.000 --> 00:00:02.500\nHello\nthere"));
        assert!(!first.contains("Later"));
        assert!(segment(1, &cues, 0.5, 0).contains("00:01:01.500 --> 00:01:02.500"));
    }
}
