//! Looking at a stream before casting it: is it HLS, how long is it, where does it start, mono or stereo.

use url::Url;

use crate::upstream::{self, Headers};
use crate::{ffmpeg, playlist, sniff};

#[derive(Debug, Default)]
pub struct Probe {
    pub duration: f64,
    /// The first segment's presentation time in seconds, or None when it couldn't be measured.
    pub start_time: Option<f64>,
    /// The first audio stream's channel count, when the first segment could be probed.
    pub audio_channels: Option<u32>,
}

pub async fn is_hls(url: &Url, headers: &Headers) -> bool {
    let path = url.path().to_ascii_lowercase();
    let extension = path.rsplit('.').next().unwrap_or("");
    if ["m3u8", "m3u"].contains(&extension) {
        return true;
    }
    if ["mp4", "m4v", "mov", "mpd", "webm", "mkv", "ts"].contains(&extension) {
        return false;
    }
    let mut headers = headers.clone();
    headers.insert("Range".into(), "bytes=0-63".into());
    match upstream::request(url, &headers).await {
        Ok(fetched) => playlist::looks_like_playlist(&fetched.body, &fetched.content_type(), &fetched.url),
        Err(_) => false,
    }
}

/// Follows the first variant to a media playlist, sums its duration and measures its first segment.
pub async fn probe(url: &Url, headers: &Headers) -> Probe {
    probe_inner(url, headers).await.unwrap_or_default()
}

async fn probe_inner(url: &Url, headers: &Headers) -> Option<Probe> {
    let (mut data, mut base) = upstream::load(url, headers).await.ok()?;
    let mut text = String::from_utf8_lossy(&data).into_owned();
    if playlist::is_master(&text) {
        if let Some(variant) = playlist::first_variant(&text, &base) {
            (data, base) = upstream::load(&variant, headers).await.ok()?;
            text = String::from_utf8_lossy(&data).into_owned();
        }
    }
    let mut result = Probe { duration: playlist::total_duration(&text), ..Probe::default() };
    // Encrypted segments can't be probed without decrypting them.
    if text.contains("METHOD=AES-128") || text.contains("METHOD=SAMPLE-AES") {
        return Some(result);
    }
    let Some(segment) = playlist::first_segment(&text, &base) else { return Some(result) };
    let mut media = Vec::new();
    if let Some((init, range)) = playlist::init_section(&text, &base) {
        media.extend_from_slice(&upstream::load(&init, &with_range(headers, range)).await.ok()?.0);
    }
    media.extend_from_slice(&upstream::load(&segment, &with_range(headers, playlist::first_segment_range(&text))).await.ok()?.0);
    let (media, extension) = match sniff::ts_offset(&media) {
        Some(offset) => (media[offset..].to_vec(), "ts".to_string()),
        None => (media, segment.path().rsplit('.').next().unwrap_or("ts").to_string()),
    };
    let (start_time, audio_channels) = measure(&media, &extension).await;
    result.start_time = start_time;
    result.audio_channels = audio_channels;
    Some(result)
}

fn with_range(headers: &Headers, range: Option<String>) -> Headers {
    let mut copy = headers.clone();
    if let Some(range) = range {
        copy.insert("Range".into(), range);
    }
    copy
}

/// The segment's start time and its first audio stream's channel count.
async fn measure(media: &[u8], extension: &str) -> (Option<f64>, Option<u32>) {
    let Some(ffprobe) = ffmpeg::tool("ffprobe") else { return (None, None) };
    let extension = if extension.is_empty() || extension.len() > 5 { "ts" } else { extension };
    let file = std::env::temp_dir().join(format!("softsubs-probe-{}.{extension}", uuid::Uuid::new_v4()));
    if tokio::fs::write(&file, media).await.is_err() {
        return (None, None);
    }
    let arguments: Vec<String> = [
        "-v", "error", "-select_streams", "a:0", "-show_entries", "format=start_time:stream=channels", "-of", "default=nw=1",
    ]
    .iter()
    .map(|s| s.to_string())
    .chain([file.to_string_lossy().into_owned()])
    .collect();
    let output = ffmpeg::run(&ffprobe, &arguments).await;
    let _ = tokio::fs::remove_file(&file).await;
    let Ok(output) = output else { return (None, None) };
    if !output.status.success() {
        return (None, None);
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let value = |key: &str| {
        text.lines().find_map(|line| line.split_once('=').filter(|(k, _)| k.trim() == key).map(|(_, v)| v.trim().to_string()))
    };
    (value("start_time").and_then(|v| v.parse().ok()), value("channels").and_then(|v| v.parse().ok()))
}
