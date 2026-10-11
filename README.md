# Soft Subs AirPlay

AirPlay web videos to your TV and keep the subtitles.

## Why normal AirPlay drops subtitles

When Safari AirPlays a `<video>`, it doesn't send what's on screen. It hands the TV the **media URL**, and the TV fetches and plays the stream itself. Only subtitles *inside* the stream (an HLS `#EXT-X-MEDIA TYPE=SUBTITLES` rendition) reach the TV. Most sites instead:

- add a sidecar `<track src="subs.vtt">`, or add cues from JavaScript (`addTextTrack` / `VTTCue`)
- draw subtitles as HTML over the video
- play the video through Media Source Extensions (`blob:` URLs: hls.js, dash.js, Shaka), which often can't be AirPlayed at all

The TV never sees any of those.

## How this works

```
Safari extension ──(stream URL, subtitle cues, cookies/referer)──▶ Soft Subs.app (127.0.0.1:47800)
                                                                    │ local HTTP server on your LAN
                                                                    │ • rewrites the HLS master playlist to
                                                                    │   add a DEFAULT WebVTT subtitle rendition
                                                                    │ • proxies every playlist/segment/key with
                                                                    │   the page's headers (the TV has no cookies)
                                                                    │ • MP4/DASH → repackaged to HLS by ffmpeg (no re-encode)
                                                                    ▼
                                                     AVPlayer + AirPlay picker ──▶ Apple TV / AirPlay 2 TV
```

The TV gets a normal HLS stream with a real subtitle track, so it renders the subtitles itself, using your caption style settings.

**Timing:** the browser's `currentTime = 0` is the stream's first presentation timestamp, which is often 10 s for TS streams. The app measures that timestamp with `ffprobe` and writes it into each WebVTT segment's `X-TIMESTAMP-MAP`, so cues line up. If they're still off, nudge them with **Timing −/+** in the app.

## Setup

```bash
brew install xcodegen ffmpeg
./build.sh --run
```

Then in Safari:

1. **Settings → Extensions** → enable **Soft Subs AirPlay**, and set it to **Allow on every website**.
2. If it isn't listed: **Settings → Advanced → Show features for web developers**, then **Develop → Allow Unsigned Extensions**. Safari resets this setting when it quits.
3. The first time you cast, allow **Local Network** access, plus the firewall prompt if one appears. The TV has to reach the app on port 47800.

## Use

1. Start the video on the site, with the subtitles you want turned on.
2. Click the **Soft Subs** toolbar button. It shows the stream it found and the available subtitles:
   - tracks from the page (`<track>` files and loaded text-track cues)
   - subtitle files seen on the network (VTT, SRT, TTML/DFXP)
   - *Stream's own subtitles*, for HLS streams that already carry them
3. Click **Send to TV**. The Soft Subs window comes forward. Pick your TV with the AirPlay button; after that, it stays selected for later casts.

`scripts/smoke-test.sh [stream-url]` casts a test stream with sample cues through the running app and prints the rebuilt playlists.

## Limits

- **DRM services** (Netflix, Disney+, Prime Video, Max, Apple TV+) can't work this way. The stream is encrypted and tied to the browser's license. Use their TV apps instead.
- Short-lived signed URLs and strict hotlink protection can still fail. Most sites work because requests carry the page's cookies, Referer and User-Agent.
- Live streams are proxied, but the subtitle track is built as video-on-demand.
- MP4/DASH sources are fully repackaged before playback starts. VP9/Opus (WebM) won't play on Apple TV without transcoding.
- "Partial" text tracks: players like hls.js load subtitle cues as playback moves forward. For those, pick *Stream's own subtitles*.

## Layout

| Path | What |
|---|---|
| `App/` | Helper app: `HTTPServer`, `StreamService` (proxy + routes), `Playlist` (HLS rewriting), `WebVTT`, `Media` (ffmpeg/ffprobe, LAN address), `CastController` (AVPlayer + API) |
| `Extension/Resources/` | Safari Web Extension (MV3): `page-hook.js` (fetch/XHR capture in the page world), `content.js`, `subtitles.js` (parsers), popup |
| `project.yml` | XcodeGen spec; `build.sh` generates the project and builds into `build/` |

## Roadmap

- Built into the Keivi browser (WKWebView), with no extension sandbox
- Chrome support (same extension; it already talks to the app over localhost)
- Record subtitles that are drawn as HTML over the video
- Burn-in fallback for receivers that ignore soft subtitles
