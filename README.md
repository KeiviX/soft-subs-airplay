# Soft Subs AirPlay

Cast web videos to your TV, **with their subtitles**: from Safari on a Mac via AirPlay, or from Chrome on Windows to AirPlay and Chromecast TVs.

Normal AirPlay drops the subtitles on most sites. Soft Subs rebuilds the video stream with the subtitles inside it, so your TV shows them as real, toggleable subtitles.

**Jump to:** [Mac (Safari)](#quick-setup) · [Windows (Chrome)](#windows-chrome)

![The Soft Subs window playing a video with subtitles](docs/app-window.png)

## Quick setup

macOS with Safari. For Windows, see [Windows (Chrome)](#windows-chrome).

```bash
curl -fsSL https://raw.githubusercontent.com/KeiviX/soft-subs-airplay/main/install.sh | bash
```

This downloads the latest release (or builds from source if there isn't one), installs **Soft Subs** to Applications, installs ffmpeg with Homebrew if it's available, and opens the app. Then:

1. In **Safari → Settings → Extensions**, turn on **Soft Subs AirPlay** and choose **Allow on every website**. The app shows an **Open Safari Settings** button until you do.
   Not listed? Go to **Settings → Advanced → Show features for web developers**, then turn on **Develop → Allow Unsigned Extensions**. Safari turns this off again whenever it quits.
2. Play a video with subtitles on, click the **Soft Subs** toolbar button, then **Send to TV**.
3. In the Soft Subs window, click the **AirPlay button in the video controls** and pick your TV.

Installer options: `… | bash -s -- --source` builds from source; `--no-ffmpeg` skips ffmpeg.

<details>
<summary>Manual install</summary>

1. Download **SoftSubs-x.y.z.zip** from [Releases](../../releases), unzip it, and move **Soft Subs** to Applications.
2. Open it. If macOS says it can't verify the developer, go to **System Settings → Privacy & Security → Open Anyway** (only needed once).
3. Enable the Safari extension as described above.
4. Optional: `brew install ffmpeg`.

</details>

## Windows (Chrome)

On Windows, the Soft Subs helper sends the video to the TV itself: **AirPlay** TVs (Apple TV, Samsung, LG, Sony…) and **Chromecast** TVs (Google TV / Android TV sets, Chromecast dongles).

### Install

1. Download **SoftSubs-Setup-x.y.z.exe** from [Releases](../../releases) and run it. Windows may show *"Windows protected your PC"* because the app isn't code-signed. Click **More info → Run anyway**.
   The installer bundles ffmpeg, allows the app through the firewall (the TV streams from your PC), and starts Soft Subs when you sign in. Look for its icon by the clock.
2. Add the Chrome extension (Developer mode):
   1. Open `chrome://extensions` and turn on **Developer mode** (top right).
   2. Click **Load unpacked** and choose `C:\Program Files\Soft Subs\chrome-extension`. The Start menu has a *Soft Subs Chrome extension folder* shortcut.
   3. Pin **Soft Subs** from the puzzle-piece menu so its button is always visible.

   Chrome may show a *"Disable developer mode extensions"* warning when it starts. Click away from it, not **Disable**. Edge works the same way at `edge://extensions`.
3. Make sure the PC and the TV are on the same network, and that Windows calls that network **Private** (Settings → Network & internet → your network). On a Public network, the firewall keeps the TV out.

### Use

1. Play the video with its subtitles on, then click the **Soft Subs** button in Chrome.
2. Choose the stream, the subtitles and your **TV**, then click **Send to <TV>**.
3. AirPlay TVs come first in the list. **They ask for a PIN the first time.** Click *Pair & manage TVs* in the popup (or the tray icon → Open Soft Subs), click **Pair**, then type the PIN the TV shows.
4. The control panel (tray icon → *Open Soft Subs*) has subtitles on/off, timing −/+ and Stop.
5. TV not showing up? The panel explains common causes (Public network, VM on NAT). You can also add the TV by its **IP address**, found under the TV's network settings.

> **Status:** the Windows version is new. AirPlay from Windows uses the open-source [pyatv](https://pyatv.dev) library, and non-Apple TVs differ in what they accept. If one TV refuses AirPlay but also has Chromecast, pick its Chromecast entry. The log is in `%LOCALAPPDATA%\SoftSubs\soft-subs.log`.

## Updating

From 0.1.1 on, Soft Subs checks GitHub for new releases:
- **Mac:** a banner in the Soft Subs window. **Update now** downloads the new version, swaps it in and reopens. The Safari extension updates with it. (The Mac app has to be in Applications. Running `install.sh` again also updates it.)
- **Windows:** **Update now** in the control panel. The extension popup also says when an update is available. It runs the new installer silently (one Windows admin prompt), and the Chrome extension reloads itself afterwards.

Coming from 0.1.0? Install 0.1.1 manually once; it has the updater.

## Requirements

| | |
|---|---|
| macOS | 15 Sequoia or later, Apple silicon or Intel |
| Windows | Windows 10 or 11 (x64; ARM64 runs it through emulation), Chrome or Edge 111+ |
| Browser | Safari on Mac; Chrome or Edge on Windows |
| TV | Mac: an AirPlay receiver (Apple TV, or an AirPlay 2 TV from Samsung, LG, Sony, Vizio…). Windows: AirPlay or Chromecast. Same network as the computer |
| ffmpeg | Mac: optional but recommended (`brew install ffmpeg`), needed for MP4/DASH sources and exact subtitle timing. Windows: bundled |
| Building from source | Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) |

## Using it

- **Choosing subtitles.** The popup lists every subtitle source it found:
  - `<track>` files on the page and text-track cues the player has loaded
  - subtitle files the page downloaded (VTT, SRT, TTML/DFXP)
  - *Stream's own subtitles*, for HLS streams that already carry them
- **Subtitles on/off and timing.** Use the **Subtitles** switch in the app. If they're out of sync, nudge them in 0.25 s steps with **Timing −/+**.
- **If your TV only shows the picture with screen mirroring.** Mirror to it (Control Center → Screen Mirroring), ideally as a separate display, then click **Full screen** / **Show on <TV>**. Esc closes it.
- **Keep the app open while you watch.** It's what streams the video to your TV.

## How it works

When Safari AirPlays a `<video>`, it doesn't send what's on screen. It hands the TV the **media URL**, and the TV fetches the stream itself. So only subtitles *inside* the stream (an HLS `#EXT-X-MEDIA TYPE=SUBTITLES` rendition) reach the TV. Most sites instead add subtitles in the page, as `<track>` files, JavaScript cues or HTML overlays, or they play through Media Source Extensions (`blob:` URLs), which can't be AirPlayed at all.

```
Safari extension ──(stream URL, subtitle cues, Referer/cookies)──▶ Soft Subs.app (127.0.0.1:47800)
                                                                    │ local HTTP server on your LAN
                                                                    │ • rewrites the HLS master playlist to
                                                                    │   add a DEFAULT WebVTT subtitle rendition
                                                                    │ • proxies every playlist/segment/key with
                                                                    │   the page's headers (the TV has no cookies)
                                                                    │ • MP4/DASH → repackaged to HLS by ffmpeg (no re-encode)
                                                                    ▼
                                                     AVPlayer (AirPlay button in its controls) ──▶ TV
```

**Timing:** the browser's `currentTime = 0` is the stream's first presentation timestamp, which is often 10 s for TS streams. The app measures that timestamp with `ffprobe` and writes it into each WebVTT segment's `X-TIMESTAMP-MAP`, so cues line up.

**Awkward hosts:** the app sends an origin-only Referer (what Safari sends cross-site), relabels MPEG-TS segments disguised as `.jpg`/`.html`, and caches the master playlist, since signed URLs expire quickly.

**Troubleshooting:** the app logs every request to `~/Library/Logs/SoftSubs/soft-subs.log`, including which device asked (Mac or TV) and what the video host answered. `last-cast.json` in the same folder holds the last cast request, including that site's cookies, and `scripts/replay-last-cast.sh` re-sends it.

## Limits

- **DRM services** (Netflix, Disney+, Prime Video, Max, Apple TV+) can't work this way. The stream is encrypted and tied to the browser's license. Use their TV apps instead.
- Some hosts with strict hotlink protection or very short-lived URLs may still refuse.
- Live streams are proxied, but the subtitle track is built as video-on-demand.
- MP4/DASH sources are fully repackaged before playback starts. VP9/Opus (WebM) won't play on most TVs without transcoding.
- "Partial" text tracks: players like hls.js load subtitle cues as playback moves forward. For those, pick *Stream's own subtitles*.

## Development

```bash
brew install xcodegen ffmpeg
./build.sh --run              # generate the Xcode project, build into build/, launch
scripts/smoke-test.sh         # cast Apple's sample stream with test cues and print the rebuilt playlists
```

`build.sh` signs with your Apple Development certificate if you have one, otherwise ad-hoc.

The Windows helper also runs on a Mac for development (`pip install -r windows/requirements.txt`, then `cd windows && python -m softsubs --no-tray --port 47801`). Tests: `python -m pytest windows/tests`. To build the installer on Windows: `powershell -ExecutionPolicy Bypass -File windows\build.ps1 -Version 0.1.0`.

| Path | What |
|---|---|
| `App/` | Helper app: `HTTPServer`, `StreamService` (proxy + routes), `Playlist` (HLS rewriting), `WebVTT`, `Media` (ffmpeg/ffprobe, LAN address), `CastController` (AVPlayer + API), `TVOutput` (full-screen fallback) |
| `Extension/Resources/` | Safari Web Extension (MV3): `page-hook.js` (fetch/XHR capture in the page world), `content.js`, `subtitles.js` (parsers), popup |
| `project.yml` | XcodeGen spec |
| `install.sh` | One-line installer |
| `scripts/release.sh` | Builds, zips and publishes a GitHub release (the Windows workflow then attaches its installer) |
| `windows/` | Windows helper (Python): `softsubs/server.py` (API + proxy), `hls.py`, `media.py`, `receivers.py` (AirPlay via pyatv, Chromecast), `panel.html`; `build.ps1` + `installer.iss` build the installer |
| `scripts/build_chrome.py` | Packages the extension for Chrome |
| `.github/workflows/windows.yml` | Builds, tests and smoke-tests the Windows installer; attaches it to releases |

### Releasing

```bash
scripts/release.sh 0.2.0 --dry-run   # build + zip into dist/
scripts/release.sh 0.2.0             # also bumps versions, tags v0.2.0 and publishes a GitHub release
```

With a **Developer ID Application** certificate in your keychain (paid Apple Developer Program), releases are signed with it. Setting `NOTARY_PROFILE` to a `xcrun notarytool store-credentials` profile also notarizes them. That removes the "Open Anyway" and "Allow Unsigned Extensions" steps for everyone else.

## Roadmap

- Built into the Keivi browser (WKWebView), with no extension sandbox
- Record subtitles that are drawn as HTML over the video
- Burn-in fallback for TVs that ignore soft subtitles
