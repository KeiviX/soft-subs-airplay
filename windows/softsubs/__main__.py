"""Starts the Soft Subs server, with a tray icon on Windows.

    SoftSubs.exe                 run with a tray icon and open the window
    SoftSubs.exe --background    run with a tray icon only (used at sign-in)
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


def open_panel(port: int) -> None:
    """Opens the control panel as its own window (Edge app mode) on Windows, else in the default browser."""
    url = f"http://127.0.0.1:{port}/"
    if sys.platform == "win32":
        import os
        import subprocess

        for root in (os.environ.get("ProgramFiles(x86)"), os.environ.get("ProgramFiles")):
            edge = os.path.join(root or "", "Microsoft", "Edge", "Application", "msedge.exe")
            if os.path.isfile(edge):
                subprocess.Popen([edge, f"--app={url}", "--window-size=620,820"])
                return
    webbrowser.open(url)


def run_tray(port: int) -> None:
    import pystray
    from PIL import Image

    from .icon import draw_icon

    icon = pystray.Icon(
        "SoftSubs", draw_icon(64), "Soft Subs",
        menu=pystray.Menu(
            pystray.MenuItem("Open Soft Subs", lambda: open_panel(port), default=True),
            pystray.MenuItem("Open log folder", lambda: webbrowser.open(DATA_DIR.as_uri())),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("Quit", lambda item: icon.stop()),
        ),
    )
    icon.run()


def main() -> None:
    parser = argparse.ArgumentParser(prog="SoftSubs")
    parser.add_argument("--no-tray", action="store_true")
    parser.add_argument("--background", action="store_true", help="start in the tray without opening the window")
    parser.add_argument("--port", type=int, default=PORT)
    parser.add_argument("url", nargs="?")
    args = parser.parse_args()

    if already_running(args.port):
        if not args.url:
            open_panel(args.port)
        return

    if args.no_tray:
        serve(args.port)
        return
    ready = threading.Event()
    threading.Thread(target=serve, args=(args.port, ready), daemon=True).start()
    ready.wait(10)
    if not args.url and not args.background:
        open_panel(args.port)  # Launched from the Start menu: show the window. At sign-in it stays in the tray.
    run_tray(args.port)


if __name__ == "__main__":
    main()
