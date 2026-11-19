//! Repackages a non-HLS source (MP4, DASH...) into fMP4 HLS without re-encoding, so a TV can play it.

use std::path::Path;
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use url::Url;

use crate::ffmpeg;
use crate::upstream::Headers;

pub async fn remux(
    url: &Url,
    headers: &Headers,
    folder: &Path,
    duration: Option<f64>,
    progress: impl Fn(f64),
) -> Result<(), String> {
    let program = ffmpeg::tool("ffmpeg").ok_or("This video isn't HLS, so it needs ffmpeg to repackage it. Run: brew install ffmpeg")?;
    tokio::fs::create_dir_all(folder).await.map_err(|error| error.to_string())?;

    let mut arguments: Vec<String> =
        ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-progress", "pipe:1"].iter().map(|s| s.to_string()).collect();
    if let Some(agent) = headers.get("User-Agent") {
        arguments.extend(["-user_agent".to_string(), agent.clone()]);
    }
    let extra: String = headers.iter().filter(|(name, _)| *name != "User-Agent").map(|(name, value)| format!("{name}: {value}\r\n")).collect();
    if !extra.is_empty() {
        arguments.extend(["-headers".to_string(), extra]);
    }
    let path = |name: &str| folder.join(name).to_string_lossy().into_owned();
    arguments.extend([
        "-i".into(), url.to_string(),
        "-map".into(), "0:v:0".into(), "-map".into(), "0:a:0?".into(), "-c".into(), "copy".into(),
        "-f".into(), "hls".into(), "-hls_time".into(), "6".into(), "-hls_playlist_type".into(), "vod".into(),
        "-hls_segment_type".into(), "fmp4".into(), "-hls_fmp4_init_filename".into(), "init.mp4".into(),
        "-hls_segment_filename".into(), path("seg%05d.m4s"),
        path("index.m3u8"),
    ]);

    let mut child = Command::new(program)
        .args(&arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|error| error.to_string())?;
    if let Some(stdout) = child.stdout.take() {
        let mut lines = BufReader::new(stdout).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if let (Some(micros), Some(duration)) = (line.strip_prefix("out_time_us="), duration.filter(|d| *d > 0.0)) {
                if let Ok(micros) = micros.trim().parse::<f64>() {
                    progress((micros / 1_000_000.0 / duration).min(1.0));
                }
            }
        }
    }
    let output = child.wait_with_output().await.map_err(|error| error.to_string())?;
    if output.status.success() {
        return Ok(());
    }
    let errors = String::from_utf8_lossy(&output.stderr);
    let message = errors.lines().last().map(str::to_string).unwrap_or_else(|| format!("exit code {:?}", output.status.code()));
    Err(format!("ffmpeg couldn't repackage the video: {message}"))
}
