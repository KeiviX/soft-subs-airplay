"""Starts the Soft Subs server, with a tray icon on Windows.

    SoftSubs.exe                 run with a tray icon
    SoftSubs.exe --no-tray       run headless (tests, other platforms)
    SoftSubs.exe softsubs://...  launched from the extension's "Start Soft Subs" link
"""

from __future__ import annotations

import argparse
import asyncio
import sys
import threading
import urllib.request
import webbrowser

from aiohttp import web

from .log import DATA_DIR, log
from .server import PORT, Controller, create_app


def already_running(port: int) -> bool:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/status", timeout=1) as response:
            return response.status == 200
    except OSError:
        return False


def serve(port: int, ready: threading.Event | None = None) -> None:
    if sys.platform == "win32":
        asyncio.set_event_loop_policy(asyncio.WindowsProactorEventLoopPolicy())

    async def main() -> None:
        runner = web.AppRunner(create_app(Controller(port)), access_log=None)
        await runner.setup()
        # All interfaces: the TV fetches the stream over the local network. The control API itself only
        # answers requests from this computer.
        await web.TCPSite(runner, host="0.0.0.0", port=port).start()
        log(f"serving on port {port}")
        if ready:
            ready.set()
        await asyncio.Event().wait()

    asyncio.run(main())


def run_tray(port: int) -> None:
    import pystray
    from PIL import Image

    from .icon import draw_icon

    panel = f"http://127.0.0.1:{port}/"
    icon = pystray.Icon(
        "SoftSubs", draw_icon(64), "Soft Subs",
        menu=pystray.Menu(
            pystray.MenuItem("Open Soft Subs", lambda: webbrowser.open(panel), default=True),
            pystray.MenuItem("Open log folder", lambda: webbrowser.open(DATA_DIR.as_uri())),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("Quit", lambda item: icon.stop()),
        ),
    )
    icon.run()


def main() -> None:
    parser = argparse.ArgumentParser(prog="SoftSubs")
    parser.add_argument("--no-tray", action="store_true")
    parser.add_argument("--port", type=int, default=PORT)
    parser.add_argument("url", nargs="?")
    args = parser.parse_args()

    if already_running(args.port):
        if not args.url:
            webbrowser.open(f"http://127.0.0.1:{args.port}/")
        return

    if args.no_tray:
        serve(args.port)
        return
    ready = threading.Event()
    threading.Thread(target=serve, args=(args.port, ready), daemon=True).start()
    ready.wait(10)
    run_tray(args.port)


if __name__ == "__main__":
    main()
