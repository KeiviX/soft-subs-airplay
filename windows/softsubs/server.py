"""The local server: the control API for the extension and control panel, and the rebuilt stream for the TV.

Mirrors App/StreamService.swift and App/CastController.swift, plus TV discovery and sending (receivers.py),
which macOS does for the Mac app.
"""

from __future__ import annotations

import asyncio
import json
import shutil
import tempfile
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import quote

from aiohttp import web

from . import __version__, hls, media
from .log import log, problem, save_last_cast, take_problem
from .receivers import Playback, Receivers

PORT = 47800
TRUSTED_ORIGINS = ("chrome-extension://", "safari-web-extension://", "moz-extension://", "extension://")


@dataclass
class Session:
    id: str
    source: str  # remote HLS URL, or a local folder holding our remux
    is_local: bool
    headers: dict[str, str]
    cues: list[hls.Cue]
    label: str
    language: str
    title: str
    offset: float = 0.0
    timestamp_base: int = 0
    duration: float = 0.0
    version: int = 0
    start: float = 0.0  # where the browser was when the cast started
    master_cache: tuple[bytes, str] | None = field(default=None, repr=False)

    @property
    def prefix(self) -> str:
        return f"/s/{self.id}"

    def subtitle_media(self) -> str | None:
        if not self.cues:
            return None
        return hls.subtitle_media(self.label, self.language, f"{self.prefix}/subs.m3u8?v={self.version}")


class Controller:
    def __init__(self, port: int = PORT) -> None:
        self.port = port
        self.upstream = media.Upstream()
        self.receivers = Receivers()
        self.sessions: dict[str, Session] = {}
        self.session_id: str | None = None
        self.phase = "idle"
        self.message = "Play a video in Chrome and click the Soft Subs button."
        self.subtitles_on = True
        self.device_id: str | None = None
        self.playback: Playback | None = None
        self._task: asyncio.Task | None = None
        self._process = None
        self._folder: Path | None = None

    @property
    def session(self) -> Session | None:
        return self.sessions.get(self.session_id or "")

    def status(self) -> dict:
        session = self.session
        return {
            "ok": True, "app": "Soft Subs", "version": __version__, "platform": "windows", "features": ["devices"],
            "phase": self.message, "state": self.phase, "playing": self.phase == "playing",
            "title": session.title if session else "", "onTV": self.playback is not None,
            "device": self.playback.device.name if self.playback else None,
            "deviceId": self.device_id, "subtitlesOn": self.subtitles_on,
            "subtitleOffset": session.offset if session else 0, "hasSubtitles": bool(session and session.cues),
            "ffmpeg": media.tool("ffmpeg") is not None, "lanAddress": media.lan_address(),
        }

    def _set(self, phase: str, message: str) -> None:
        self.phase, self.message = phase, message
        log(f"{phase}: {message}")

    # Casting

    async def cast(self, request: dict) -> str:
        await self.stop()
        session_id = uuid.uuid4().hex
        self.session_id = session_id
        self.subtitles_on = not request.get("subtitlesOff", False)
        self.device_id = request.get("device") or self.device_id
        self._set("preparing", "Loading the stream…")
        self._task = asyncio.create_task(self._prepare_and_send(session_id, request))
        return session_id

    async def _prepare_and_send(self, session_id: str, request: dict) -> None:
        try:
            url = request.get("url", "")
            if not url.startswith(("http://", "https://")):
                raise media.UpstreamError("The page didn't give a usable video URL.")
            headers = request.get("headers") or {}
            subtitles = request.get("subtitles") or {}
            cues = sorted((hls.Cue(float(c["start"]), float(c["end"]), str(c.get("text", "")))
                           for c in subtitles.get("cues", []) if float(c["end"]) > float(c["start"])),
                          key=lambda cue: cue.start)
            session = Session(id=session_id, source=url, is_local=False, headers=headers, cues=cues,
                              label=subtitles.get("label") or "Subtitles", language=subtitles.get("language") or "",
                              title=request.get("title") or "Video", start=float(request.get("startTime") or 0))

            if not await media.is_hls(self.upstream, url, headers):
                folder = Path(tempfile.gettempdir()) / "SoftSubs" / session_id
                self._folder = folder
                self._set("preparing", "Repackaging the video for your TV…")
                duration = request.get("duration")

                def progress(fraction: float) -> None:
                    if self.session_id == session_id:
                        self.message = f"Repackaging the video for your TV… {int(fraction * 100)}%"

                await media.remux(url, headers, folder, duration, progress,
                                  register=lambda process: setattr(self, "_process", process))
                self._process = None
                session.source, session.is_local = str(folder / "index.m3u8"), True

            self._set("preparing", "Lining up the subtitles…")
            duration, start_time = await media.probe(self.upstream, session.source, headers)
            session.duration = max(duration, request.get("duration") or 0)
            session.timestamp_base = int(max(0.0, start_time or 0.0) * 90_000)
            log(f"probe duration={duration} start={start_time} cues={len(cues)}")
            self.sessions[session_id] = session

            if not self.device_id:
                self._set("ready", "Ready. Pick your TV in the Soft Subs popup or control panel.")
                return
            await self.send(self.device_id)
        except asyncio.CancelledError:
            raise
        except Exception as error:
            if self.session_id == session_id:
                self._set("failed", _describe(error))

    async def send(self, device_id: str, start: float | None = None) -> None:
        session = self.session
        if session is None:
            raise LookupError("Nothing to send yet.")
        if start is None:
            start = self.playback.position if self.playback else session.start
        if self.playback:
            await self.playback.stop()
            self.playback = None
        self.device_id = device_id
        device = await self.receivers.device(device_id)
        address = media.lan_address()
        if not address:
            raise media.UpstreamError("This computer isn't on a local network, so the TV can't reach it.")
        base = f"http://{address}:{self.port}{session.prefix}"
        is_cast = device.kind == "chromecast"
        # Chromecast gets the subtitles as one sidecar file it can switch on and off; AirPlay TVs get them
        # inside the stream, and turning them off means reloading without them.
        include_in_stream = self.subtitles_on and not is_cast
        master = f"{base}/master.m3u8?v={session.version}&subs={int(include_in_stream)}"
        sidecar = f"{base}/subs.vtt?v={session.version}" if is_cast and session.cues else None
        self._set("preparing", f"Starting on {device.name}…")
        take_problem()
        try:
            self.playback = await self.receivers.play(device, master, sidecar, start, session.title, self._finished)
        except Exception as error:
            upstream = take_problem()
            raise RuntimeError(_describe(error) + (f" ({upstream})" if upstream else "")) from error
        if is_cast and not self.subtitles_on:
            await self.playback.set_subtitles(False)
        self._set("playing", f"Playing on {device.name}.")

    def _finished(self, error) -> None:
        if self.phase == "playing":
            self._set("failed" if error else "idle", f"{_describe(error)}" if error else "Finished playing.")
        self.playback = None

    async def set_subtitles(self, on: bool) -> None:
        self.subtitles_on = on
        if self.playback and not await self.playback.set_subtitles(on):
            await self.send(self.playback.device.id)

    async def nudge(self, delta: float) -> None:
        session = self.session
        if session is None:
            return
        session.offset = round(session.offset + delta, 2)
        session.version += 1
        if self.playback:
            await self.send(self.playback.device.id)

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            self._task = None
        if self._process and self._process.returncode is None:
            self._process.terminate()
        self._process = None
        if self.playback:
            try:
                await self.playback.stop()
            except Exception as error:
                log(f"stop failed: {error!r}")
            self.playback = None
        if self._folder:
            shutil.rmtree(self._folder, ignore_errors=True)
            self._folder = None
        self.sessions.clear()
        self.session_id = None
        self._set("idle", "Play a video in Chrome and click the Soft Subs button.")


def _describe(error: BaseException | None) -> str:
    if error is None:
        return ""
    text = str(error) or error.__class__.__name__
    return text if text.endswith(".") or text.endswith(")") else text + "."


# HTTP


def _json(data: dict, status: int = 200) -> web.Response:
    return web.json_response(data, status=status)


def _error(status: int, message: str) -> web.Response:
    return _json({"ok": False, "error": message}, status)


def _playlist(text: str) -> web.Response:
    return web.Response(text=text, content_type=hls.MIME)


@web.middleware
async def cors(request: web.Request, handler):
    response = web.Response(status=204) if request.method == "OPTIONS" else await handler(request)
    response.headers.update({"Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "Content-Type",
                             "Access-Control-Allow-Methods": "GET, POST, OPTIONS"})
    return response


def create_app(controller: Controller) -> web.Application:
    app = web.Application(middlewares=[cors], client_max_size=50 * 1024 * 1024)
    port = controller.port
    panel_origin = (f"http://127.0.0.1:{port}", f"http://localhost:{port}")

    def trusted(request: web.Request) -> bool:
        """The control API only answers this computer, and only the extension, the panel or local tools."""
        origin = request.headers.get("Origin")
        host = request.headers.get("Host", "")
        return (request.remote in ("127.0.0.1", "::1") and host.startswith(("127.0.0.1", "localhost"))
                and (origin is None or origin.startswith(TRUSTED_ORIGINS) or origin in panel_origin))

    async def api(request: web.Request) -> web.Response:
        if not trusted(request):
            return _error(403, "Forbidden")
        name = request.match_info["name"]
        body = await request.read() if request.method == "POST" else b""
        data = json.loads(body or b"{}") if body else {}
        try:
            if name == "status":
                return _json(controller.status())
            if name == "devices":
                devices = (await controller.receivers.scan() if request.query.get("refresh") or
                           not controller.receivers.devices else controller.receivers.devices.values())
                return _json({"ok": True, "devices": [d.public() for d in devices]})
            if name == "cast":
                save_last_cast(body)
                log(f"cast {data.get('url')} subtitles={len((data.get('subtitles') or {}).get('cues', []))} "
                    f"device={data.get('device')}")
                return _json({"ok": True, "session": await controller.cast(data)})
            if name == "send":
                await controller.send(data["device"])
                return _json({"ok": True})
            if name == "subtitles":
                await controller.set_subtitles(bool(data.get("on")))
                return _json({"ok": True})
            if name == "nudge":
                await controller.nudge(float(data.get("delta", 0)))
                return _json({"ok": True})
            if name == "stop":
                await controller.stop()
                return _json({"ok": True})
            if name == "pair":
                if data.get("pin"):
                    paired = await controller.receivers.finish_pairing(data["device"], str(data["pin"]))
                    return _json({"ok": paired, **({} if paired else {"error": "Wrong PIN, try again."})})
                await controller.receivers.begin_pairing(data["device"])
                return _json({"ok": True})
        except Exception as error:
            log(f"api {name} failed: {error!r}")
            controller.message = _describe(error)
            return _error(400, _describe(error))
        return _error(404, "Not found")

    async def stream(request: web.Request) -> web.StreamResponse:
        session = controller.sessions.get(request.match_info["session"])
        if session is None:
            return _error(404, "Unknown session")
        rest = request.match_info["rest"]
        log(f"from {request.remote} {request.method} {rest[:60]} ua={request.headers.get('User-Agent', '-')[:40]}")

        if rest == "master.m3u8":
            return await master(session, include_subtitles=request.query.get("subs", "1") == "1")
        if rest == "subs.m3u8":
            duration = max(session.duration, max((c.end for c in session.cues), default=0) + session.offset, 1)
            return _playlist(hls.subtitle_playlist(duration, lambda i: f"{session.prefix}/subs/{i}.vtt?v={session.version}"))
        if rest == "subs.vtt":
            return web.Response(text=hls.subtitle_file(session.cues, session.offset), content_type="text/vtt")
        if rest.startswith("subs/") and rest.endswith(".vtt"):
            index = int(rest[5:-4])
            body = hls.subtitle_segment(index, session.cues, session.offset, session.timestamp_base)
            return web.Response(text=body, content_type="text/vtt")
        if rest == "p":
            return await proxy(session, request)
        if rest.startswith("local/") and session.is_local:
            folder = Path(session.source).parent.resolve()
            file = (folder / rest[6:]).resolve()
            if folder in file.parents and file.is_file():
                content_type = hls.MIME if file.suffix == ".m3u8" else "video/mp4"
                return web.Response(body=file.read_bytes(), content_type=content_type)
        return _error(404, "Not found")

    def proxy_path(session: Session, url: str) -> str:
        return f"{session.prefix}/p?u={quote(url, safe='')}"

    async def master(session: Session, include_subtitles: bool) -> web.Response:
        subtitles = session.subtitle_media() if include_subtitles else None
        if session.is_local:
            return _playlist(hls.synthetic_master(f"{session.prefix}/local/index.m3u8", subtitles))
        try:
            if session.master_cache is None:
                # Signed stream URLs often expire within minutes, and receivers re-request the master on reload.
                session.master_cache = await controller.upstream.load(session.source, session.headers)
            data, final_url = session.master_cache
        except Exception as error:
            problem(f"master playlist: {error}")
            return _error(502, str(error))
        text = data.decode(errors="replace")
        if not hls.is_master(text):
            return _playlist(hls.synthetic_master(proxy_path(session, final_url), subtitles))
        proxied = hls.rewrite(text, final_url, lambda url: proxy_path(session, url))
        # With no cues of our own, keep whatever subtitles the stream already carries.
        if not session.cues:
            return _playlist(proxied)
        return _playlist(hls.replacing_subtitles(proxied, subtitles))

    async def proxy(session: Session, request: web.Request) -> web.Response:
        url = request.query.get("u", "")
        if not url.startswith(("http://", "https://")):
            return _error(400, "Bad URL")
        headers = dict(session.headers)
        if "Range" in request.headers:
            headers["Range"] = request.headers["Range"]
        try:
            status, response_headers, body, final_url = await controller.upstream.request(url, headers)
        except Exception as error:
            problem(f"{url.split('/')[2]}: {error!r}")
            return _error(502, str(error))
        content_type = response_headers.get("Content-Type", "")
        log(f"upstream {status} {content_type} {len(body)}B {final_url.split('?')[0][-60:]}")
        if not 200 <= status < 300:
            problem(f"{final_url.split('/')[2]} returned HTTP {status} for {final_url.split('?')[0].rsplit('/', 1)[-1]}")
            return web.Response(status=status, body=body)
        if hls.looks_like_playlist(body, content_type, final_url):
            return _playlist(hls.rewrite(body.decode(errors="replace"), final_url,
                                         lambda u: proxy_path(session, u)))
        if "mp2t" not in content_type.lower() and (ts := media.unwrap_ts(body)) is not None:
            response = web.Response(status=status, body=ts, content_type="video/mp2t")
            if len(ts) == len(body) and "Content-Range" in response_headers:
                response.headers["Content-Range"] = response_headers["Content-Range"]
            return response
        response = web.Response(status=status, body=body)
        for name in ("Content-Type", "Content-Range", "Accept-Ranges"):
            if name in response_headers:
                response.headers[name] = response_headers[name]
        return response

    async def panel(_: web.Request) -> web.Response:
        return web.Response(text=(Path(__file__).parent / "panel.html").read_text(encoding="utf-8"),
                            content_type="text/html")

    app.router.add_get("/", panel)
    app.router.add_route("*", "/api/{name}", api)
    app.router.add_route("*", "/s/{session}/{rest:.*}", stream)

    async def cleanup(_: web.Application) -> None:
        await controller.stop()
        await controller.upstream.close()

    async def startup(_: web.Application) -> None:
        # Find TVs in the background so the popup's first look at the list is instant.
        asyncio.get_running_loop().create_task(controller.receivers.scan())

    app.on_startup.append(startup)
    app.on_cleanup.append(cleanup)
    return app
