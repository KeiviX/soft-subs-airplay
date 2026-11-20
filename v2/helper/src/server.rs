//! The HTTP server: the extension's API (`/api/...`), and per-cast routes under `/s/<id>/` that serve the
//! player page and the rebuilt stream to the browser and the TV.

use axum::body::Body;
use axum::extract::{ConnectInfo, Request, State};
use axum::response::{IntoResponse, Response};
use bytes::Bytes;
use futures::FutureExt;
use percent_encoding::{utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};
use serde::Deserialize;
use serde_json::json;
use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, RwLock, Weak};
use std::time::{Duration, Instant};
use tokio::task::JoinHandle;
use url::Url;

use crate::audiofix::AudioFix;
use crate::cache::SegmentCache;
use crate::resp::Resp;
use crate::upstream::{self, Headers};
use crate::webvtt::{self, Cue};
use crate::{dlna, ffmpeg, lan, log, playlist, probe, remux, sniff};

const PLAYER_PAGE: &str = include_str!("player.html");

/// Characters left as-is in the proxied URL query value; everything else is percent-encoded.
const URL_VALUE: &AsciiSet = &NON_ALPHANUMERIC.remove(b'-').remove(b'.').remove(b'_').remove(b'~');

#[derive(Clone)]
enum Source {
    /// A remote HLS stream, proxied segment by segment.
    Hls(Url),
    /// A folder holding our ffmpeg remux (`index.m3u8` plus fMP4 segments).
    Local(PathBuf),
}

#[derive(Clone)]
struct Session {
    id: String,
    source: Source,
    /// Sent with every upstream request (Referer, Cookie, User-Agent...), since the TV has none of the browser's.
    headers: Headers,
    cues: Vec<Cue>,
    subtitle_label: String,
    subtitle_language: String,
    subtitle_offset: f64,
    timestamp_base: u64,
    duration: f64,
    /// Bumped when the subtitles change, so the player reloads them instead of using its cached copy.
    version: u32,
    /// The source master playlist as first fetched; signed stream URLs often expire within minutes.
    master_cache: Option<(Bytes, Url)>,
    audio_fix: AudioFix,
}

impl Session {
    fn prefix(&self) -> String {
        format!("/s/{}", self.id)
    }

    fn subtitle_media(&self) -> Option<String> {
        (!self.cues.is_empty()).then(|| {
            playlist::subtitle_media(
                &self.subtitle_label,
                &self.subtitle_language,
                &format!("{}/subs.m3u8?v={}", self.prefix(), self.version),
            )
        })
    }

    fn proxy_path(&self, url: &Url) -> String {
        format!("{}/p?u={}", self.prefix(), utf8_percent_encode(url.as_str(), URL_VALUE))
    }
}

#[derive(Clone, PartialEq)]
enum Phase {
    Idle,
    Preparing(String),
    Ready,
    Failed(String),
}

/// What the player page last said about playback.
#[derive(Clone)]
struct PlayerReport {
    wireless: bool,
    playing: bool,
    at: Instant,
}

#[derive(Default)]
struct Cast {
    session_id: Option<String>,
    phase: Option<Phase>,
    title: String,
    start_time: f64,
    subtitle_summary: String,
    subtitle_track: Option<String>,
    report: Option<PlayerReport>,
    task: Option<JoinHandle<()>>,
    remux_folder: Option<PathBuf>,
    /// The DLNA TV this cast was sent to; None means the browser plays it (AirPlay).
    device: Option<dlna::Renderer>,
}

pub struct App {
    pub port: u16,
    sessions: RwLock<HashMap<String, Session>>,
    caches: Mutex<HashMap<String, Arc<SegmentCache>>>,
    cast: Mutex<Cast>,
    devices: Mutex<dlna::Registry>,
    /// Set once a Chrome-based browser's extension has talked to the helper, so the Mac app's setup
    /// banner can stop asking for Safari.
    chrome_used: std::sync::atomic::AtomicBool,
    me: Weak<App>,
}

impl App {
    pub fn new(port: u16) -> Arc<App> {
        Arc::new_cyclic(|me| App {
            port,
            sessions: RwLock::new(HashMap::new()),
            caches: Mutex::new(HashMap::new()),
            cast: Mutex::new(Cast::default()),
            devices: Mutex::new(dlna::Registry::default()),
            chrome_used: std::sync::atomic::AtomicBool::new(false),
            me: me.clone(),
        })
    }

    fn session(&self, id: &str) -> Option<Session> {
        self.sessions.read().unwrap().get(id).cloned()
    }

    fn update_session(&self, id: &str, change: impl FnOnce(&mut Session)) -> Option<Session> {
        let mut sessions = self.sessions.write().unwrap();
        let session = sessions.get_mut(id)?;
        change(session);
        Some(session.clone())
    }

    /// Changes the cast's phase, but only if `id` is still the current cast.
    fn set_phase(&self, id: &str, phase: Phase) {
        let mut cast = self.cast.lock().unwrap();
        if cast.session_id.as_deref() == Some(id) {
            cast.phase = Some(phase);
        }
    }

    /// The session's segment cache. Caches for sessions that have ended are dropped to free their memory.
    fn cache(&self, session: &Session) -> Arc<SegmentCache> {
        let mut caches = self.caches.lock().unwrap();
        if let Some(cache) = caches.get(&session.id) {
            return Arc::clone(cache);
        }
        let live: Vec<String> = self.sessions.read().unwrap().keys().cloned().collect();
        caches.retain(|id, _| live.contains(id));
        let me = self.me.clone();
        let snapshot = session.clone();
        let cache = SegmentCache::new(Arc::new(move |url: Url| {
            let me = me.clone();
            let session = snapshot.clone();
            async move {
                match me.upgrade() {
                    Some(app) => app.fetch(&session, url, None, None).await,
                    None => Resp::error(410, "Stopped"),
                }
            }
            .boxed()
        }));
        caches.insert(session.id.clone(), Arc::clone(&cache));
        cache
    }

    // MARK: Routing

    pub async fn handle(self: Arc<Self>, remote: SocketAddr, request: Request) -> Resp {
        let method = request.method().as_str().to_string();
        let path = request.uri().path().to_string();
        let query: HashMap<String, String> =
            url::form_urlencoded::parse(request.uri().query().unwrap_or("").as_bytes()).into_owned().collect();
        // Read in their own scope: the request body isn't Sync, so nothing may borrow it across an await.
        let (origin, range, agent) = {
            let header = |name: &str| request.headers().get(name).and_then(|v| v.to_str().ok()).map(str::to_string);
            // "bytes=0-" (ffmpeg sends it) asks for the whole file, so treat it like no Range at all.
            let range = header("range").filter(|range| range.replace(' ', "") != "bytes=0-");
            (header("origin"), range, header("user-agent"))
        };
        let body = axum::body::to_bytes(request.into_body(), 64 << 20).await.unwrap_or_default();

        if method == "OPTIONS" {
            return Resp::new(204, Bytes::new());
        }
        if path == "/" {
            return Resp::text("Soft Subs helper v2 is running.\n", "text/plain; charset=utf-8");
        }
        if let Some(endpoint) = path.strip_prefix("/api/") {
            // Only the browser extension (or tools without an Origin, like curl) may start or stop casts.
            let trusted = origin.as_deref().map_or(true, |origin| {
                ["safari-web-extension://", "chrome-extension://", "moz-extension://", "webkit-extension://"]
                    .iter()
                    .any(|prefix| origin.starts_with(prefix))
            });
            if !trusted {
                return Resp::error(403, "Forbidden");
            }
            if origin.as_deref().is_some_and(|origin| origin.starts_with("chrome-extension://")) {
                self.chrome_used.store(true, std::sync::atomic::Ordering::Relaxed);
            }
            return match (method.as_str(), endpoint) {
                ("GET", "status") => self.status(),
                ("GET", "devices") => self.devices(query.contains_key("refresh")),
                // The Mac app restarts an outdated helper after an update; launchd starts the new one.
                ("POST", "quit") if remote.ip().is_loopback() && origin.is_none() => {
                    log::log("quitting at the app's request");
                    tokio::spawn(async {
                        tokio::time::sleep(Duration::from_millis(200)).await;
                        std::process::exit(0);
                    });
                    Resp::json(json!({ "ok": true }))
                }
                ("POST", "cast") => self.start_cast(&body),
                ("POST", "stop") => {
                    self.stop();
                    Resp::json(json!({ "ok": true }))
                }
                _ => Resp::error(404, "Not found"),
            };
        }

        let parts: Vec<&str> = path.trim_start_matches('/').splitn(3, '/').collect();
        let ["s", id, rest] = parts.as_slice() else { return Resp::error(404, "Not found") };
        let (id, rest) = (id.to_string(), rest.to_string());

        // The player page's own routes work while the cast is still being prepared.
        match (method.as_str(), rest.as_str()) {
            ("GET", "player") => return Resp::text(PLAYER_PAGE, "text/html; charset=utf-8").header("Cache-Control", "no-store"),
            ("GET", "info") => return self.info(&id),
            ("POST", "state") => return self.player_state(&id, &body),
            ("POST", "offset") => return self.nudge_subtitles(&id, &body),
            ("POST", "dlna/play" | "dlna/pause" | "dlna/seek") | ("GET", "dlna/position") => {
                return self.dlna_control(&id, &rest[5..], &body).await;
            }
            ("POST", "stop") => {
                if self.cast.lock().unwrap().session_id.as_deref() == Some(id.as_str()) {
                    self.stop();
                }
                return Resp::json(json!({ "ok": true }));
            }
            _ => {}
        }

        let Some(session) = self.session(&id) else { return Resp::error(404, "Unknown session") };
        let short: String = rest.chars().take(60).collect();
        log::log(format!(
            "from {} {method} {short} range={} ua={}",
            remote.ip(),
            range.as_deref().unwrap_or("-"),
            agent.as_deref().unwrap_or("-").chars().take(40).collect::<String>()
        ));

        match rest.as_str() {
            "master.m3u8" => self.master(&session, start_position(&query)).await,
            "subs.srt" => Resp::text(webvtt::srt(&session.cues, session.subtitle_offset), "text/srt; charset=utf-8"),
            "subs.m3u8" => {
                let last_cue = session.cues.iter().map(|cue| cue.end).fold(0.0, f64::max) + session.subtitle_offset;
                let duration = session.duration.max(last_cue).max(1.0);
                let prefix = session.prefix();
                let version = session.version;
                Resp::text(webvtt::playlist(duration, |i| format!("{prefix}/subs/{i}.vtt?v={version}")), playlist::MIME)
            }
            "p" => self.proxy(&session, query.get("u"), range, start_position(&query)).await,
            _ => {
                if let Some(index) = rest.strip_prefix("subs/").and_then(|name| name.trim_end_matches(".vtt").parse::<usize>().ok()) {
                    let body = webvtt::segment(index, &session.cues, session.subtitle_offset, session.timestamp_base);
                    return Resp::text(body, "text/vtt; charset=utf-8");
                }
                if let (Some(name), Source::Local(folder)) = (rest.strip_prefix("local/"), &session.source) {
                    return serve_file(folder, name).await;
                }
                Resp::error(404, "Not found")
            }
        }
    }

    // MARK: API

    fn status(&self) -> Resp {
        let cast = self.cast.lock().unwrap();
        let phase = cast.phase.clone().unwrap_or(Phase::Idle);
        let recent = cast.report.as_ref().filter(|report| report.at.elapsed() < Duration::from_secs(10));
        let on_tv = phase == Phase::Ready && recent.is_some_and(|report| report.wireless);
        let playing = phase == Phase::Ready && recent.is_some_and(|report| report.playing);
        let player_url = cast.session_id.as_ref().and_then(|id| self.player_url(id));
        let phase_line = match (&phase, &cast.device) {
            (Phase::Ready, Some(device)) => format!("Playing on {}. Control it from the Soft Subs tab.", device.name),
            _ => phase_text(&phase, recent),
        };
        Resp::json(json!({
            "ok": true,
            "platform": if cfg!(target_os = "macos") { "mac" } else { "windows" },
            "v2": true,
            // A Chrome-based browser's extension reloads itself when this differs from its own version.
            "version": env!("CARGO_PKG_VERSION"),
            "phase": phase_line,
            "playing": playing || (phase == Phase::Ready && cast.device.is_some()),
            "onTV": on_tv || (phase == Phase::Ready && cast.device.is_some()),
            // The extension shows a TV list (AirPlay, plus DLNA TVs found on the network).
            "features": ["devices"],
            "chromeUsed": self.chrome_used.load(std::sync::atomic::Ordering::Relaxed),
            // The Mac app restarts the helper when its bundled copy is newer than this, or isn't this one.
            "startedAt": started_at(),
            "executable": std::env::current_exe().ok().map(|path| path.to_string_lossy().into_owned()),
            "title": cast.title,
            "lanAddress": lan::current(),
            "ffmpeg": ffmpeg::available(),
            "subtitleTrack": cast.subtitle_track,
            "session": cast.session_id,
            "playerUrl": player_url,
        }))
    }

    fn player_url(&self, id: &str) -> Option<String> {
        lan::current().map(|address| format!("http://{address}:{}/s/{id}/player", self.port))
    }

    fn start_cast(self: &Arc<Self>, body: &[u8]) -> Resp {
        log::save_last_cast(body);
        let request: CastRequest = match serde_json::from_slice(body) {
            Ok(request) => request,
            Err(error) => return Resp::error(400, format!("Invalid cast request: {error}")),
        };
        log::log(format!(
            "cast {} subtitles={} headers={:?}",
            request.url,
            request.subtitles.as_ref().map_or(0, |s| s.cues.len()),
            request.headers.as_ref().map(|h| { let mut keys: Vec<_> = h.keys().cloned().collect(); keys.sort(); keys }).unwrap_or_default()
        ));
        let device = match request.device.as_deref() {
            Some(id) if id.starts_with("dlna:") => match self.devices.lock().unwrap().renderers.get(id).cloned() {
                Some(renderer) => Some(renderer),
                None => return Resp::error(404, "That TV isn't on the network any more. Refresh the TV list and try again."),
            },
            _ => None,
        };
        let id = uuid::Uuid::new_v4().to_string();
        let Some(player_url) = self.player_url(&id) else {
            return Resp::error(503, "This computer isn't on a local network, so the TV can't reach it.");
        };
        self.stop();
        let app = Arc::clone(self);
        let task_id = id.clone();
        {
            let mut cast = self.cast.lock().unwrap();
            cast.session_id = Some(id.clone());
            cast.phase = Some(Phase::Preparing("Loading the stream…".into()));
            cast.title = request.title.clone().unwrap_or_else(|| "Video".into());
            cast.start_time = request.start_time.unwrap_or(0.0);
            cast.report = None;
            cast.device = device;
            let _ = log::take_problem();
            cast.task = Some(tokio::spawn(async move { app.prepare(task_id, request).await }));
        }
        Resp::json(json!({ "ok": true, "session": id, "playerUrl": player_url }))
    }

    async fn prepare(self: Arc<Self>, id: String, request: CastRequest) {
        if let Err(message) = self.prepare_inner(&id, request).await {
            log::log(format!("cast failed: {message}"));
            self.set_phase(&id, Phase::Failed(message));
        }
    }

    async fn prepare_inner(&self, id: &str, request: CastRequest) -> Result<(), String> {
        let url = Url::parse(&request.url)
            .ok()
            .filter(|url| matches!(url.scheme(), "http" | "https"))
            .ok_or("The page didn't give a usable video URL.")?;
        let headers = request.headers.clone().unwrap_or_default();
        let subtitles = request.subtitles.clone();
        let mut cues: Vec<Cue> = subtitles.as_ref().map(|s| s.cues.clone()).unwrap_or_default();
        cues.retain(|cue| cue.end > cue.start);
        cues.sort_by(|a, b| a.start.total_cmp(&b.start));
        let mut session = Session {
            id: id.to_string(),
            source: Source::Hls(url.clone()),
            headers: headers.clone(),
            subtitle_label: subtitles.as_ref().and_then(|s| s.label.clone()).unwrap_or_else(|| "Subtitles".into()),
            subtitle_language: subtitles.as_ref().and_then(|s| s.language.clone()).unwrap_or_default(),
            cues,
            subtitle_offset: 0.0,
            timestamp_base: 0,
            duration: 0.0,
            version: 0,
            master_cache: None,
            audio_fix: AudioFix::None,
        };

        if !probe::is_hls(&url, &headers).await {
            if !ffmpeg::available() {
                return Err("This video isn't HLS, so it needs ffmpeg to repackage it. Run: brew install ffmpeg".into());
            }
            let folder = std::env::temp_dir().join("SoftSubs").join(id);
            self.cast.lock().unwrap().remux_folder = Some(folder.clone());
            self.set_phase(id, Phase::Preparing("Repackaging the video for your TV…".into()));
            remux::remux(&url, &headers, &folder, request.duration, |fraction| {
                self.set_phase(id, Phase::Preparing(format!("Repackaging the video for your TV… {}%", (fraction * 100.0) as u32)));
            })
            .await?;
            session.source = Source::Local(folder);
        }

        self.set_phase(id, Phase::Preparing("Lining up the subtitles…".into()));
        let probe_url = match &session.source {
            Source::Hls(url) => url.clone(),
            Source::Local(folder) => Url::from_file_path(folder.join("index.m3u8")).map_err(|_| "bad remux folder")?,
        };
        let probe = probe::probe(&probe_url, &headers).await;
        session.duration = probe.duration.max(request.duration.unwrap_or(0.0));
        session.timestamp_base = (probe.start_time.unwrap_or(0.0).max(0.0) * 90_000.0) as u64;
        session.audio_fix = AudioFix::choose(probe.audio_channels);
        log::log(format!(
            "probe duration={} start={} audioChannels={} audioFix={} cues={}",
            probe.duration,
            probe.start_time.map_or("unknown".into(), |s| s.to_string()),
            probe.audio_channels.map_or("unknown".into(), |c| c.to_string()),
            session.audio_fix.name(),
            session.cues.len()
        ));

        let summary = if session.cues.is_empty() {
            if request.subtitles_off.unwrap_or(false) { "Subtitles off.".to_string() } else { "Using the stream's own subtitles, if it has any.".to_string() }
        } else {
            let mut summary = format!("{}: {} lines", session.subtitle_label, session.cues.len());
            if probe.start_time.is_none() {
                summary += " (start time unknown, use Earlier/Later if they're out of sync)";
            }
            summary
        };
        let track = (!session.cues.is_empty()).then(|| session.subtitle_label.clone());
        self.sessions.write().unwrap().insert(id.to_string(), session);
        let (device, start_time) = {
            let mut cast = self.cast.lock().unwrap();
            if cast.session_id.as_deref() == Some(id) {
                cast.subtitle_summary = summary;
                cast.subtitle_track = track;
                cast.phase = Some(Phase::Ready);
            }
            (cast.device.clone(), cast.start_time)
        };
        if let Some(renderer) = device {
            self.dlna_load(id, &renderer, start_time).await?;
        }
        Ok(())
    }

    fn stop(&self) {
        let mut cast = self.cast.lock().unwrap();
        if let Some(task) = cast.task.take() {
            task.abort();
        }
        if let Some(id) = cast.session_id.take() {
            self.sessions.write().unwrap().remove(&id);
            self.caches.lock().unwrap().remove(&id);
        }
        if let Some(folder) = cast.remux_folder.take() {
            let _ = std::fs::remove_dir_all(folder);
        }
        if let Some(renderer) = cast.device.take() {
            tokio::spawn(async move {
                let _ = dlna::stop(&renderer).await;
            });
        }
        *cast = Cast::default();
    }

    // MARK: Player page

    fn info(&self, id: &str) -> Resp {
        let cast = self.cast.lock().unwrap();
        if cast.session_id.as_deref() != Some(id) {
            return Resp::json(json!({ "state": "stopped", "phase": "This cast has ended. Start a new one from the extension." }));
        }
        let phase = cast.phase.clone().unwrap_or(Phase::Idle);
        let state = match &phase {
            Phase::Ready => "ready",
            Phase::Failed(_) => "failed",
            _ => "preparing",
        };
        let session = self.session(id);
        Resp::json(json!({
            "state": state,
            "phase": phase_text(&phase, None),
            "title": cast.title,
            "startTime": cast.start_time,
            "subtitles": cast.subtitle_summary,
            "mode": if cast.device.is_some() { "dlna" } else { "airplay" },
            "device": cast.device.as_ref().map(|d| d.name.clone()),
            "offset": session.as_ref().map_or(0.0, |s| s.subtitle_offset),
            "master": session.as_ref().map(|s| format!("{}/master.m3u8?v={}", s.prefix(), s.version)),
        }))
    }

    fn player_state(&self, id: &str, body: &[u8]) -> Resp {
        #[derive(Deserialize)]
        struct Report {
            wireless: bool,
            playing: bool,
            time: Option<f64>,
            note: Option<String>,
        }
        let Ok(report) = serde_json::from_slice::<Report>(body) else { return Resp::error(400, "Bad report") };
        let mut cast = self.cast.lock().unwrap();
        if cast.session_id.as_deref() == Some(id) {
            if let Some(note) = &report.note {
                log::log(format!("player at {:.1}s: {note}", report.time.unwrap_or(0.0)));
            }
            let was_wireless = cast.report.as_ref().is_some_and(|r| r.wireless);
            if was_wireless != report.wireless {
                log::log(if report.wireless { "player: now on the TV" } else { "player: back on this computer" });
            }
            cast.report = Some(PlayerReport { wireless: report.wireless, playing: report.playing, at: Instant::now() });
        }
        Resp::json(json!({ "ok": true }))
    }

    /// Positive deltas show subtitles later. The player reloads the stream to pick up the change.
    fn nudge_subtitles(&self, id: &str, body: &[u8]) -> Resp {
        #[derive(Deserialize)]
        struct Nudge {
            delta: f64,
        }
        let Ok(nudge) = serde_json::from_slice::<Nudge>(body) else { return Resp::error(400, "Bad request") };
        let updated = self.update_session(id, |session| {
            session.subtitle_offset = ((session.subtitle_offset + nudge.delta) * 100.0).round() / 100.0;
            session.version += 1;
        });
        let device = self.cast.lock().unwrap().device.clone();
        if let (Some(renderer), Some(_)) = (device, &updated) {
            // The TV reads the .srt once, so reload the video (with the new subtitles) where it is.
            let app = self.me.upgrade();
            let id = id.to_string();
            tokio::spawn(async move {
                let Some(app) = app else { return };
                let at = dlna::position(&renderer).await.map(|p| p.time).unwrap_or(0.0);
                if let Err(error) = app.dlna_load(&id, &renderer, at).await {
                    log::problem(error);
                }
            });
        }
        match updated {
            Some(session) => Resp::json(json!({
                "ok": true,
                "offset": session.subtitle_offset,
                "master": format!("{}/master.m3u8?v={}", session.prefix(), session.version),
            })),
            None => Resp::error(404, "Unknown session"),
        }
    }

    // MARK: DLNA

    /// TVs to offer in the extension. Searching takes a few seconds, so it runs in the background and the
    /// extension polls while `scanning` is true.
    fn devices(&self, refresh: bool) -> Resp {
        let mut registry = self.devices.lock().unwrap();
        if (refresh || registry.renderers.is_empty()) && !registry.scanning {
            registry.scanning = true;
            let app = self.me.clone();
            tokio::spawn(async move {
                let found = dlna::discover(Duration::from_secs(3)).await;
                let Some(app) = app.upgrade() else { return };
                let mut registry = app.devices.lock().unwrap();
                for renderer in found {
                    registry.renderers.insert(renderer.id.clone(), renderer);
                }
                registry.scanning = false;
            });
        }
        let mut devices = Vec::new();
        if cfg!(target_os = "macos") {
            devices.push(json!({ "id": "airplay", "name": "AirPlay TV" }));
        }
        let mut renderers: Vec<&dlna::Renderer> = registry.renderers.values().collect();
        renderers.sort_by(|a, b| a.name.cmp(&b.name));
        for renderer in renderers {
            devices.push(json!({ "id": renderer.id, "name": format!("{} (DLNA)", renderer.name) }));
        }
        Resp::json(json!({ "ok": true, "devices": devices, "scanning": registry.scanning }))
    }

    /// Sends the session's continuous stream (and subtitles) to the TV, starting at `at` seconds.
    async fn dlna_load(&self, id: &str, renderer: &dlna::Renderer, at: f64) -> Result<(), String> {
        let session = self.session(id).ok_or("The cast has ended.")?;
        let address = lan::current().ok_or("This computer isn't on a local network, so the TV can't reach it.")?;
        let base = format!("http://{address}:{}{}", self.port, session.prefix());
        let mkv = use_mkv(&session);
        let url = format!("{base}/dlna.{}?v={}", if mkv { "mkv" } else { "ts" }, session.version);
        // In an MKV the subtitles are inside the file; only the TS variant points the TV at an .srt.
        let subtitles = (!mkv && !session.cues.is_empty()).then(|| format!("{base}/subs.srt?v={}", session.version));
        let title = self.cast.lock().unwrap().title.clone();
        log::log(format!("DLNA: sending to {} from {at:.1}s", renderer.name));
        let mime = if mkv { dlna::MKV_MIME } else { dlna::TS_MIME };
        let media = dlna::Media { url: &url, mime, title: &title, duration: session.duration, subtitles: subtitles.as_deref() };
        dlna::play_media(renderer, &media).await?;
        if at > 5.0 {
            // A TV ignores Seek until it's actually playing.
            for _ in 0..30 {
                tokio::time::sleep(Duration::from_millis(500)).await;
                if dlna::position(renderer).await.is_ok_and(|p| p.state == "PLAYING") {
                    break;
                }
            }
            dlna::seek(renderer, at).await?;
        }
        Ok(())
    }

    /// Remote control for the player page: play, pause, seek and position.
    async fn dlna_control(&self, id: &str, action: &str, body: &[u8]) -> Resp {
        let renderer = {
            let cast = self.cast.lock().unwrap();
            match (&cast.device, cast.session_id.as_deref() == Some(id)) {
                (Some(renderer), true) => renderer.clone(),
                _ => return Resp::error(404, "This cast isn't playing on a DLNA TV."),
            }
        };
        let result = match action {
            "play" => dlna::play(&renderer).await,
            "pause" => dlna::pause(&renderer).await,
            "seek" => {
                #[derive(Deserialize)]
                struct Seek {
                    to: f64,
                }
                let Ok(seek) = serde_json::from_slice::<Seek>(body) else { return Resp::error(400, "Bad request") };
                dlna::seek(&renderer, seek.to).await
            }
            _ => {
                return match dlna::position(&renderer).await {
                    Ok(p) => Resp::json(json!({ "ok": true, "time": p.time, "duration": p.duration, "state": p.state })),
                    Err(error) => Resp::error(502, error),
                };
            }
        };
        match result {
            Ok(()) => Resp::json(json!({ "ok": true })),
            Err(error) => {
                log::log(format!("DLNA {action} failed: {error}"));
                Resp::error(502, error)
            }
        }
    }

    /// The first variant's media playlist, as a URL on this helper, for ffmpeg to read.
    async fn video_playlist_url(&self, session: &Session) -> Option<String> {
        let master = self.master_playlist(session).await;
        if !master.ok() {
            return None;
        }
        let base = Url::parse(&format!("http://127.0.0.1:{}/", self.port)).ok()?;
        playlist::first_variant(&String::from_utf8_lossy(&master.body), &base).map(|url| url.to_string())
    }

    /// One continuous MPEG-TS stream for a DLNA TV: ffmpeg reads the (proxied, fixed-up) HLS through this
    /// helper and copies it without re-encoding. A `TimeSeekRange.dlna.org` request starts it elsewhere.
    async fn dlna_stream(&self, id: &str, mkv: bool, head: bool, seek: Option<f64>, remote: SocketAddr) -> Response {
        let Some(session) = self.session(id) else { return Resp::error(404, "Unknown session").into_response() };
        let with_subtitles = mkv && !session.cues.is_empty();
        let mut builder = Response::builder()
            .status(200)
            .header("Content-Type", if mkv { dlna::MKV_MIME } else { dlna::TS_MIME })
            .header("contentFeatures.dlna.org", dlna::CONTENT_FEATURES)
            .header("transferMode.dlna.org", "Streaming");
        if !mkv && !session.cues.is_empty() {
            if let Some(address) = lan::current() {
                let url = format!("http://{address}:{}{}/subs.srt?v={}", self.port, session.prefix(), session.version);
                builder = builder.header("CaptionInfo.sec", url);
            }
        }
        if let Some(start) = seek {
            let duration = session.duration;
            builder = builder.header("TimeSeekRange.dlna.org", format!("npt={start:.3}-{duration:.3}/{duration:.3}"));
        }
        if head {
            // An empty body would be sent as `Content-Length: 0`, which a TV reads as an empty video.
            // An empty stream has no known length, like the real response.
            let nothing = futures::stream::empty::<Result<Bytes, std::io::Error>>();
            return builder.body(Body::from_stream(nothing)).unwrap_or_default();
        }
        let (Some(input), Some(program)) = (self.video_playlist_url(&session).await, ffmpeg::tool("ffmpeg")) else {
            return Resp::error(502, "The stream isn't available.").into_response();
        };
        let mut arguments: Vec<String> = ["-hide_banner", "-loglevel", "error", "-nostdin", "-allowed_extensions", "ALL", "-extension_picky", "0"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let start = seek.filter(|start| *start > 0.5);
        let mut add_input = |url: String| {
            if let Some(start) = start {
                // Copied video has to start at the keyframe before the seek point. Without this, re-encoded
                // audio would start exactly at it instead (seconds later), and the TV lines the two up by
                // their first frames, so speech ran seconds behind the picture after a jump.
                arguments.extend(["-noaccurate_seek".to_string(), "-ss".to_string(), format!("{start:.3}")]);
            }
            arguments.extend(["-i".to_string(), url]);
        };
        add_input(input);
        if with_subtitles {
            add_input(format!("http://127.0.0.1:{}{}/subs.srt?v={}", self.port, session.prefix(), session.version));
        }
        let mut output: Vec<&str> = vec!["-map", "0:v:0", "-map", "0:a:0?"];
        if with_subtitles {
            let language = playlist::language_tag(&session.subtitle_language)
                .or_else(|| playlist::language_tag(&session.subtitle_label))
                .unwrap_or_else(|| "und".into());
            arguments.extend(["-metadata:s:s:0".to_string(), format!("language={language}")]);
            arguments.extend(["-metadata:s:s:0".to_string(), format!("title={}", session.subtitle_label)]);
            output.extend(["-map", "1:0", "-c:s", "srt", "-disposition:s:0", "default"]);
        }
        // -copyts keeps the source timestamps after a seek, so the TV's clock (and its subtitle timing) reads
        // 5:00 after a jump to 5:00 rather than starting again from 0:00.
        output.extend(["-c:v", "copy", "-copyts"]);
        if mkv {
            // ffmpeg can't copy this AAC into Matroska ("unable to determine samplerate"), so re-encode the
            // audio, which is cheap, and make it stereo while at it. All tracks on by default for the TV.
            // Written as it goes, with no index at the end, since the TV reads it as a stream.
            output.extend(["-c:a", "aac", "-ac", "2", "-b:a", "192k", "-disposition:v:0", "default", "-disposition:a:0", "default"]);
            output.extend(["-f", "matroska", "-live", "1", "pipe:1"]);
        } else {
            output.extend(["-c:a", "copy", "-muxdelay", "0", "-muxpreload", "0", "-f", "mpegts", "pipe:1"]);
        }
        arguments.extend(output.iter().map(|s| s.to_string()));
        let child = tokio::process::Command::new(program)
            .args(&arguments)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true)
            .spawn();
        let mut child = match child {
            Ok(child) => child,
            Err(error) => return Resp::error(500, error.to_string()).into_response(),
        };
        log::log(format!("DLNA stream to {} from {:.1}s", remote.ip(), seek.unwrap_or(0.0)));
        if let Some(stderr) = child.stderr.take() {
            tokio::spawn(async move {
                use tokio::io::AsyncBufReadExt;
                let mut lines = tokio::io::BufReader::new(stderr).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    log::log(format!("ffmpeg: {line}"));
                }
            });
        }
        let Some(stdout) = child.stdout.take() else { return Resp::error(500, "no output").into_response() };
        // The child rides along with the stream, so ffmpeg is killed when the TV hangs up.
        let stream = futures::stream::unfold((stdout, child), |(mut stdout, child)| async move {
            use tokio::io::AsyncReadExt;
            let mut buffer = bytes::BytesMut::with_capacity(64 * 1024);
            match stdout.read_buf(&mut buffer).await {
                Ok(0) | Err(_) => None,
                Ok(_) => Some((Ok::<Bytes, std::io::Error>(buffer.freeze()), (stdout, child))),
            }
        });
        builder.body(Body::from_stream(stream)).unwrap_or_default()
    }

    // MARK: Stream

    async fn master(&self, session: &Session, start: Option<f64>) -> Resp {
        let response = self.master_playlist(session).await;
        match start {
            Some(start) if response.ok() => {
                let text = String::from_utf8_lossy(&response.body).into_owned();
                Resp::text(playlist::starting_at(&text, start, true), playlist::MIME)
            }
            _ => response,
        }
    }

    async fn master_playlist(&self, session: &Session) -> Resp {
        let url = match &session.source {
            Source::Local(_) => {
                let media = format!("{}/local/index.m3u8", session.prefix());
                return Resp::text(playlist::synthetic_master(&media, session.subtitle_media().as_deref()), playlist::MIME);
            }
            Source::Hls(url) => url,
        };
        let (data, final_url) = match &session.master_cache {
            Some(cached) => cached.clone(),
            None => match upstream::load(url, &session.headers).await {
                Ok(loaded) => {
                    self.update_session(&session.id, |s| s.master_cache = Some(loaded.clone()));
                    loaded
                }
                Err(error) => {
                    log::problem(format!("master playlist {}: {error}", url.host_str().unwrap_or("")));
                    return Resp::error(502, error);
                }
            },
        };
        if let Some(reason) = playlist::unreadable_reason(&data, final_url.host_str()) {
            log::problem(&reason);
            return Resp::error(502, reason);
        }
        let text = String::from_utf8_lossy(&data);
        if !playlist::is_master(&text) {
            let media = session.proxy_path(&final_url);
            return Resp::text(playlist::synthetic_master(&media, session.subtitle_media().as_deref()), playlist::MIME);
        }
        let proxied = playlist::rewrite(&text, &final_url, |u| session.proxy_path(u));
        // With no cues of our own, keep whatever subtitles the stream already carries.
        let output = if session.cues.is_empty() { proxied } else { playlist::replacing_subtitles(&proxied, session.subtitle_media().as_deref()) };
        Resp::text(output, playlist::MIME)
    }

    async fn proxy(&self, session: &Session, raw: Option<&String>, range: Option<String>, start: Option<f64>) -> Resp {
        let Some(url) = raw.and_then(|raw| Url::parse(raw).ok()).filter(|url| matches!(url.scheme(), "http" | "https")) else {
            return Resp::error(400, "Bad URL");
        };
        if range.is_none() {
            let cache = self.cache(session);
            if cache.is_segment(&url) {
                return cache.response(url).await;
            }
        }
        self.fetch(session, url, range, start).await
    }

    async fn fetch(&self, session: &Session, url: Url, range: Option<String>, start: Option<f64>) -> Resp {
        let mut headers = session.headers.clone();
        if let Some(range) = &range {
            headers.insert("Range".into(), range.clone());
        }
        let is_segment = self.cache(session).is_segment(&url);
        let result = if is_segment { upstream::segment(&url, &headers).await } else { upstream::request(&url, &headers).await };
        let fetched = match result {
            Ok(fetched) => fetched,
            Err(error) => {
                log::problem(format!("{}: {error}", url.host_str().unwrap_or("the video host")));
                return Resp::error(502, error);
            }
        };
        let content_type = fetched.content_type();
        let host = fetched.url.host_str().unwrap_or("").to_string();
        let name = format!("{host}/…/{}", fetched.url.path_segments().and_then(|mut p| p.next_back()).unwrap_or(""));
        log::log(format!("upstream {} {content_type} {}B {name}", fetched.status, fetched.body.len()));
        if !fetched.ok() {
            log::problem(format!("{host} returned HTTP {} for {name}", fetched.status));
            return Resp::new(fetched.status, fetched.body);
        }
        if playlist::looks_like_playlist(&fetched.body, &content_type, &fetched.url) {
            if let Some(reason) = playlist::unreadable_reason(&fetched.body, Some(&host)) {
                log::problem(&reason);
                return Resp::error(502, reason);
            }
            let text = String::from_utf8_lossy(&fetched.body);
            self.cache(session).register(playlist::segments(&text, &fetched.url));
            let rewritten = playlist::rewrite(&text, &fetched.url, |u| session.proxy_path(u));
            let output = match start {
                Some(start) => playlist::starting_at(&rewritten, start, playlist::is_master(&rewritten)),
                None => rewritten,
            };
            return Resp::text(output, playlist::MIME);
        }
        if !content_type.to_ascii_lowercase().contains("mp2t") {
            if let Some(offset) = sniff::ts_offset(&fetched.body) {
                if offset > 0 {
                    log::log(format!("disguised TS segment ({content_type}, {offset}B prefix) {name}"));
                }
                let mut body = fetched.body.slice(offset..);
                if range.is_none() {
                    body = session.audio_fix.apply(body, &name).await;
                }
                let mut response = Resp::new(fetched.status, body).header("Content-Type", "video/mp2t");
                if offset == 0 {
                    if let Some(range) = fetched.header("content-range") {
                        response = response.header("Content-Range", range);
                    }
                }
                return response;
            }
        }
        let body = if range.is_none() && content_type.to_ascii_lowercase().contains("mp2t") {
            session.audio_fix.apply(fetched.body.clone(), &name).await
        } else {
            fetched.body.clone()
        };
        let mut response = Resp::new(fetched.status, body);
        for name in ["content-type", "content-range", "accept-ranges"] {
            if let Some(value) = fetched.header(name) {
                response = response.header(name, value);
            }
        }
        response
    }
}

fn phase_text(phase: &Phase, report: Option<&PlayerReport>) -> String {
    match phase {
        Phase::Idle => "Open a video in your browser and click the Soft Subs button.".into(),
        Phase::Preparing(message) => message.clone(),
        Phase::Ready => match report {
            Some(report) if report.wireless => "Playing on your TV.".into(),
            Some(_) => "Playing in the Soft Subs tab. Click its TV button and pick your TV.".into(),
            None => "Ready. In the Soft Subs tab, click Play on TV and pick your TV.".into(),
        },
        Phase::Failed(message) => {
            let ended = message.trim_end().ends_with(['.', '!', '?', ')']);
            format!("{}{} Let's try a different source.", message.trim_end(), if ended { "" } else { "." })
        }
    }
}

async fn serve_file(folder: &PathBuf, name: &str) -> Resp {
    let file = folder.join(name);
    let inside = file.canonicalize().ok().zip(folder.canonicalize().ok()).is_some_and(|(file, folder)| file.starts_with(folder));
    if !inside || name.contains("..") {
        return Resp::error(404, "Not found");
    }
    let Ok(data) = tokio::fs::read(&file).await else { return Resp::error(404, "Not found") };
    let content_type = match file.extension().and_then(|e| e.to_str()) {
        Some("m3u8") => playlist::MIME,
        Some("m4s" | "mp4") => "video/mp4",
        _ => "application/octet-stream",
    };
    Resp::new(200, data).header("Content-Type", content_type)
}

/// What the browser extension sends to `POST /api/cast`.
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CastRequest {
    url: String,
    title: Option<String>,
    headers: Option<Headers>,
    start_time: Option<f64>,
    duration: Option<f64>,
    subtitles: Option<Subtitles>,
    subtitles_off: Option<bool>,
    /// The TV picked in the extension: "airplay", or a DLNA renderer's id.
    device: Option<String>,
}

#[derive(Clone, Deserialize)]
struct Subtitles {
    label: Option<String>,
    language: Option<String>,
    cues: Vec<Cue>,
}

pub async fn route(State(app): State<Arc<App>>, ConnectInfo(remote): ConnectInfo<SocketAddr>, request: Request) -> Response {
    // The DLNA stream is the one response that isn't buffered in memory.
    let path = request.uri().path().to_string();
    let dlna_stream = path.strip_prefix("/s/").and_then(|rest| {
        rest.strip_suffix("/dlna.ts").map(|id| (id, false)).or_else(|| rest.strip_suffix("/dlna.mkv").map(|id| (id, true)))
    });
    if let Some((id, mkv)) = dlna_stream {
        let id = id.to_string();
        let head = request.method() == axum::http::Method::HEAD;
        let seek = request
            .headers()
            .get("timeseekrange.dlna.org")
            .and_then(|value| value.to_str().ok())
            .and_then(dlna::time_seek_start);
        log::log(format!(
            "from {} {} dlna.{} seek={}",
            remote.ip(),
            request.method(),
            if mkv { "mkv" } else { "ts" },
            seek.map_or("-".to_string(), |s| format!("{s:.1}"))
        ));
        return app.dlna_stream(&id, mkv, head, seek, remote).await;
    }
    app.handle(remote, request).await.into_response()
}

/// The `start` query value: where the player should begin, in seconds. Seeking an AirPlay TV through the
/// browser can hang (Samsung never confirms the seek, so Safari queues every later one), so the player page
/// jumps by reloading the stream with a start position written into the playlists instead.
fn start_position(query: &HashMap<String, String>) -> Option<f64> {
    query.get("start").and_then(|value| value.parse::<f64>().ok()).filter(|start| start.is_finite() && *start > 0.5)
}

/// Matroska for DLNA casts with subtitles (they go inside the file), MPEG-TS otherwise.
/// `SOFTSUBS_DLNA_CONTAINER=ts|mkv` overrides it for testing.
fn use_mkv(session: &Session) -> bool {
    match std::env::var("SOFTSUBS_DLNA_CONTAINER").as_deref() {
        Ok("ts") => false,
        Ok("mkv") => true,
        _ => !session.cues.is_empty(),
    }
}

/// When this helper started, in seconds since 1970.
fn started_at() -> u64 {
    static STARTED: std::sync::OnceLock<u64> = std::sync::OnceLock::new();
    *STARTED.get_or_init(|| {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
    })
}

pub fn mark_started() {
    let _ = started_at();
}
