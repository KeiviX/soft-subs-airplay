"""Checks GitHub for a newer release and installs it: downloads the setup .exe and runs it silently."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import aiohttp

from . import __version__
from .log import log

LATEST_RELEASE = "https://api.github.com/repos/KeiviX/soft-subs-airplay/releases/latest"
CHECK_EVERY = 6 * 60 * 60


def _version(text: str) -> tuple[int, ...]:
    parts = []
    for part in text.lstrip("v").split("."):
        digits = "".join(ch for ch in part if ch.isdigit())
        parts.append(int(digits or 0))
    return tuple(parts)


class Updater:
    def __init__(self) -> None:
        self._checked_at = 0.0
        self.latest: str | None = None
        self.installer_url: str | None = None
        self.installing = False

    @property
    def available(self) -> bool:
        return bool(self.latest and self.installer_url and _version(self.latest) > _version(__version__))

    def info(self) -> dict:
        return {"current": __version__, "latest": self.latest, "available": self.available,
                "installing": self.installing}

    async def check(self, force: bool = False) -> dict:
        if force or time.monotonic() - self._checked_at > CHECK_EVERY:
            self._checked_at = time.monotonic()
            try:
                async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=15)) as session:
                    async with session.get(LATEST_RELEASE, headers={"Accept": "application/vnd.github+json"}) as response:
                        release = await response.json() if response.status == 200 else {}
                self.latest = release.get("tag_name", "").lstrip("v") or None
                self.installer_url = next((asset["browser_download_url"] for asset in release.get("assets", [])
                                           if asset["name"].startswith("SoftSubs-Setup-") and asset["name"].endswith(".exe")), None)
                log(f"update check: current {__version__}, latest {self.latest}")
            except Exception as error:
                log(f"update check failed: {error!r}")
        return self.info()

    async def install(self) -> None:
        """Downloads the installer and runs it silently; it closes this app, updates it and starts it again."""
        if sys.platform != "win32":
            raise RuntimeError("Automatic updates are for the Windows app.")
        await self.check()
        if not self.available:
            raise RuntimeError("Soft Subs is already up to date.")
        self.installing = True
        path = Path(tempfile.gettempdir()) / f"SoftSubs-Setup-{self.latest}.exe"
        try:
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=600)) as session:
                async with session.get(self.installer_url) as response:
                    response.raise_for_status()
                    path.write_bytes(await response.read())
        except Exception:
            self.installing = False
            raise
        log(f"running {path}")
        subprocess.Popen([str(path), "/SILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/CLOSEAPPLICATIONS"],
                         creationflags=subprocess.DETACHED_PROCESS)
        # Leave the installer a moment to start, then get out of its way.
        await __import__("asyncio").sleep(2)
        os._exit(0)
