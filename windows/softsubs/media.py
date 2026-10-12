"""Fetching from the video host, measuring stream start times with ffprobe and repackaging with ffmpeg.

A port of App/Media.swift and the Upstream part of App/StreamService.swift.
"""

from __future__ import annotations

import asyncio
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path
from urllib.parse import urlsplit

import aiohttp

from . import hls
from .log import log

_NO_WINDOW = subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0


class UpstreamError(Exception):
    pass


class Upstream:
    def __init__(self) -> None:
        self._session: aiohttp.ClientSession | None = None

    async def session(self) -> aiohttp.ClientSession:
        if self._session is None or self._session.closed:
            self._session = aiohttp.ClientSession(
                cookie_jar=aiohttp.DummyCookieJar(), timeout=aiohttp.ClientTimeout(total=60, sock_read=30)
            )
        return self._session

    async def request(self, url: str, headers: dict[str, str]) -> tuple[int, dict[str, str], bytes, str]:
        """Returns (status, headers, body, final URL). A 401/403 is retried with an origin-only Referer, which is
        what browsers send cross-site and what hotlink-protected hosts expect."""
        result = await self._send(url, headers)
        referer = headers.get("Referer")
        if result[0] in (401, 403) and referer:
            parts = urlsplit(referer)
            origin = f"{parts.scheme}://{parts.netloc}/"
            if referer != origin:
                result = await self._send(url, {**headers, "Referer": origin})
        return result

    async def _send(self, url: str, headers: dict[str, str]) -> tuple[int, dict[str, str], bytes, str]:
        session = await self.session()
        async with session.get(url, headers=headers, allow_redirects=True) as response:
            body = await response.read()
            return response.status, dict(response.headers), body, str(response.url)

    async def load(self, url: str, headers: dict[str, str]) -> tuple[bytes, str]:
        """Loads an http(s) URL (raising on non-2xx) or reads a local file path."""
        if not url.startswith(("http://", "https://")):
            return Path(url).read_bytes(), url
        status, _, body, final_url = await self.request(url, headers)
        if not 200 <= status < 300:
            raise UpstreamError(f"{urlsplit(url).hostname} refused the request (HTTP {status}).")
        return body, final_url

    async def close(self) -> None:
        if self._session:
            await self._session.close()


def tool(name: str) -> str | None:
    """ffmpeg/ffprobe: bundled next to the app first, then PATH and Homebrew."""
    executable = name + (".exe" if sys.platform == "win32" else "")
    bundle = Path(getattr(sys, "_MEIPASS", Path(sys.executable).parent))
    for candidate in (bundle / "ffmpeg" / executable, Path(sys.executable).parent / "ffmpeg" / executable):
        if candidate.is_file():
            return str(candidate)
    return shutil.which(name) or next(
        (p for p in (f"/opt/homebrew/bin/{name}", f"/usr/local/bin/{name}") if os.access(p, os.X_OK)), None
    )


def unwrap_ts(data: bytes) -> bytes | None:
    """Some sites disguise MPEG-TS segments as images (.jpg names, image/jpeg types, sometimes fake image bytes
    in front). hls.js tolerates that; TVs don't. Returns the TS data, or None if it isn't MPEG-TS."""
    head = data[: 64 * 1024]

    def is_ts(offset: int) -> bool:
        return offset + 376 < len(head) and head[offset] == head[offset + 188] == head[offset + 376] == 0x47

    if len(head) <= 188 * 3:
        return None
    if is_ts(0):
        return data
    if head[4:8] in (b"ftyp", b"styp", b"moof", b"sidx"):
        return None
    for offset in range(1, len(head) - 188 * 2):
        if is_ts(offset):
            return data[offset:]
    return None


async def is_hls(upstream: Upstream, url: str, headers: dict[str, str]) -> bool:
    path = urlsplit(url).path.lower()
    if path.endswith((".m3u8", ".m3u")):
        return True
    if path.endswith((".mp4", ".m4v", ".mov", ".mpd", ".webm", ".mkv", ".ts")):
        return False
    try:
        _, response_headers, body, final_url = await upstream.request(url, {**headers, "Range": "bytes=0-63"})
    except Exception:
        return False
    return hls.looks_like_playlist(body, response_headers.get("Content-Type", ""), final_url)


async def run(*args: str, on_output=None, register=None) -> tuple[int, str, str]:
    process = await asyncio.create_subprocess_exec(
        *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, creationflags=_NO_WINDOW
    )
    if register:
        register(process)
    output: list[str] = []

    async def read_stdout() -> None:
        assert process.stdout
        async for raw in process.stdout:
            line = raw.decode(errors="replace")
            output.append(line)
            if on_output:
                on_output(line.strip())

    reader = asyncio.create_task(read_stdout())
    assert process.stderr
    errors = (await process.stderr.read()).decode(errors="replace")
    await reader
    return await process.wait(), "".join(output), errors


async def probe(upstream: Upstream, url: str, headers: dict[str, str]) -> tuple[float, float | None]:
    """Follows the first variant to a media playlist. Returns (duration, first segment's start time or None)."""
    try:
        data, base = await upstream.load(url, headers)
        text = data.decode(errors="replace")
        if hls.is_master(text) and (variant := hls.first_variant(text, base)):
            data, base = await upstream.load(variant, headers)
            text = data.decode(errors="replace")
        duration = hls.total_duration(text)
        if "METHOD=AES-128" in text or "METHOD=SAMPLE-AES" in text:
            return duration, None
        segment = hls.first_segment(text, base)
        if not segment:
            return duration, None
        media = b""
        if init := hls.init_section(text, base):
            init_url, init_range = init
            media += (await upstream.load(init_url, {**headers, **({"Range": init_range} if init_range else {})}))[0]
        segment_range = hls.first_segment_range(text)
        media += (await upstream.load(segment, {**headers, **({"Range": segment_range} if segment_range else {})}))[0]
        return duration, await _start_time(media, segment)
    except Exception as error:
        log(f"probe failed: {error}")
        return 0.0, None


async def _start_time(media: bytes, segment_url: str) -> float | None:
    ffprobe = tool("ffprobe")
    if not ffprobe:
        return None
    ts = unwrap_ts(media)
    suffix = ".ts" if ts else (Path(urlsplit(segment_url).path).suffix or ".ts")
    path = Path(tempfile.gettempdir()) / f"softsubs-probe-{uuid.uuid4().hex}{suffix}"
    path.write_bytes(ts or media)
    try:
        status, output, _ = await run(ffprobe, "-v", "error", "-show_entries", "format=start_time",
                                      "-of", "default=nw=1:nk=1", str(path))
        return float(output.strip()) if status == 0 and output.strip() else None
    except (OSError, ValueError):
        return None
    finally:
        path.unlink(missing_ok=True)


async def remux(url: str, headers: dict[str, str], folder: Path, duration: float | None, progress, register) -> None:
    """Repackages a non-HLS source (MP4, DASH...) into fMP4 HLS without re-encoding."""
    ffmpeg = tool("ffmpeg")
    if not ffmpeg:
        raise UpstreamError("This video isn't HLS, so it needs ffmpeg to repackage it, and ffmpeg wasn't found.")
    folder.mkdir(parents=True, exist_ok=True)
    args = [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-progress", "pipe:1"]
    if "User-Agent" in headers:
        args += ["-user_agent", headers["User-Agent"]]
    extra = "".join(f"{k}: {v}\r\n" for k, v in headers.items() if k != "User-Agent")
    if extra:
        args += ["-headers", extra]
    args += ["-i", url, "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy",
             "-f", "hls", "-hls_time", "6", "-hls_playlist_type", "vod",
             "-hls_segment_type", "fmp4", "-hls_fmp4_init_filename", "init.mp4",
             "-hls_segment_filename", str(folder / "seg%05d.m4s"), str(folder / "index.m3u8")]

    def on_output(line: str) -> None:
        if duration and line.startswith("out_time_us="):
            try:
                progress(min(1.0, int(line[12:]) / 1_000_000 / duration))
            except ValueError:
                pass

    status, _, errors = await run(*args, on_output=on_output, register=register)
    if status != 0:
        message = errors.strip().splitlines()[-1] if errors.strip() else f"exit code {status}"
        raise UpstreamError(f"ffmpeg couldn't repackage the video: {message}")


def lan_address() -> str | None:
    """This computer's address on the local network, which the TV uses to reach the stream server."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe_socket:
        try:
            probe_socket.connect(("192.0.2.1", 9))  # Never sent; just picks the outgoing interface.
            address = probe_socket.getsockname()[0]
        except OSError:
            return None
    return None if address.startswith("127.") else address
