# Soft Subs v2 helper (Rust)

A windowless replacement for the Mac app's streaming side. The browser extension sends it a stream and opens
its player page; the browser's own AirPlay hands the video to the TV, and the TV fetches everything from
this helper.

What it does for each cast:

- Proxies the HLS playlists and segments with the page's headers (Referer, cookies), since the TV has none.
- Downloads about 90 seconds ahead and retries stalled downloads on a fresh connection, so CDN hiccups
  don't reach the TV.
- Unwraps segments disguised as images (fake PNG/JPEG bytes in front of MPEG-TS).
- Converts mono AAC to stereo. Samsung's AirPlay player drops mono audio on and off.
- Adds the page's subtitles as an HLS WebVTT track that the TV renders.
- Repackages non-HLS sources (MP4, DASH) with ffmpeg.
- Serves the player page (`/s/<id>/player`): Play on TV, skip and go-to, subtitle timing, Stop.

## Build and run

Rust is pinned for this folder in `rust-toolchain.toml`; rustup installs it on first build.

```sh
cargo test
cargo build --release
./target/release/softsubs-helper        # listens on port 47800; SOFTSUBS_PORT changes it
```

ffmpeg and ffprobe (`brew install ffmpeg`) are needed for the audio fix, probing and repackaging.

Logs go to `~/Library/Logs/SoftSubs/soft-subs.log`, with lines tagged `[v2]`. To force an audio mode while
testing, set `SOFTSUBS_AUDIO_FIX=none|strip|stereo`.

## Notes

- Seeking an AirPlay TV through Safari can hang: the Samsung never confirms a seek that arrives while a new
  stream is starting, and Safari then holds every later seek behind it. The player page seeks normally,
  and if a seek is still unconfirmed after 6 seconds it reloads the stream with the start time written into
  the playlist (`#EXT-X-START`) and set as Safari's start position.
- Not packaged yet: for now the helper is started by hand.
