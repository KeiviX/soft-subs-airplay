"""Finding TVs and sending the rebuilt stream to them.

The Windows app casts to Chromecast receivers via pychromecast: Google TV / Android TV sets with
Chromecast built in (Sony, Philips, TCL, Hisense…) and Chromecast dongles. No pairing is needed.
"""

from __future__ import annotations

import asyncio
import ipaddress
import json
import time
from dataclasses import dataclass, field
from typing import Any

import pychromecast

from .log import DATA_DIR, log


@dataclass
class Device:
    id: str
    name: str
    kind: str  # "chromecast"
    address: str
    config: Any = field(default=None, repr=False)

    def public(self) -> dict:
        return {"id": self.id, "name": self.name, "kind": self.kind, "address": self.address, "needsPairing": False}


class Playback:
    """A stream playing on a Chromecast."""

    def __init__(self, device: Device, start: float, cast, browser) -> None:
        self.device = device
        self.cast = cast
        self.browser = browser
        self._start = start
        self._started_at = time.monotonic()

    @property
    def position(self) -> float:
        status = self.cast.media_controller.status
        if status and status.adjusted_current_time:
            return status.adjusted_current_time
        return self._start + (time.monotonic() - self._started_at)

    async def set_subtitles(self, on: bool) -> bool:
        """Turns the sidecar subtitle track on/off without restarting playback."""
        controller = self.cast.media_controller
        await asyncio.to_thread(controller.enable_subtitle if on else controller.disable_subtitle, *([1] if on else []))
        return True

    async def stop(self) -> None:
        def stop() -> None:
            try:
                self.cast.media_controller.stop()
            finally:
                self.cast.disconnect()
                pychromecast.discovery.stop_discovery(self.browser)

        await asyncio.to_thread(stop)


class Receivers:
    def __init__(self) -> None:
        self.devices: dict[str, Device] = {}
        self._scan_lock = asyncio.Lock()
        self._hosts_file = DATA_DIR / "tv-addresses.json"
        try:
            self.manual_hosts: list[str] = json.loads(self._hosts_file.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self.manual_hosts = []

    async def add_host(self, address: str) -> list[Device]:
        """Remembers a TV by IP address, for networks where automatic discovery (multicast) doesn't get through."""
        try:
            address = str(ipaddress.ip_address(address.strip()))
        except ValueError:
            raise ValueError(f"“{address}” isn't an IP address. It looks like 192.168.1.50.") from None
        added = address not in self.manual_hosts
        if added:
            self.manual_hosts.append(address)
        devices = await self.scan()
        if not any(device.address == address for device in devices):
            if added:
                self.manual_hosts.remove(address)
            raise LookupError(f"No Chromecast TV answered at {address}. Is it on, and is the address right?")
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        self._hosts_file.write_text(json.dumps(self.manual_hosts), encoding="utf-8")
        return devices

    @property
    def scanning(self) -> bool:
        return self._scan_lock.locked()

    def scan_in_background(self) -> None:
        if not self.scanning:
            asyncio.get_running_loop().create_task(self.scan())

    async def scan(self) -> list[Device]:
        async with self._scan_lock:
            try:
                found = await asyncio.to_thread(self._scan_chromecast, self.manual_hosts)
            except Exception as error:
                log(f"scan failed: {error!r}")
                found = []
            self.devices = {device.id: device for device in sorted(found, key=lambda d: d.name)}
            log(f"devices: {[d.name for d in found]}")
            return found

    @staticmethod
    def _scan_chromecast(known_hosts: list[str]) -> list[Device]:
        services, browser = pychromecast.discovery.discover_chromecasts(timeout=4, known_hosts=known_hosts or None)
        pychromecast.discovery.stop_discovery(browser)
        return [Device(id=f"chromecast:{info.uuid}", name=info.friendly_name, kind="chromecast",
                       address=str(info.host), config=info) for info in services]

    async def device(self, device_id: str) -> Device:
        if device_id not in self.devices:
            await self.scan()
        if device_id not in self.devices:
            raise LookupError("That TV isn't on the network right now. Is it on?")
        return self.devices[device_id]

    async def play(self, device: Device, master_url: str, subtitles_url: str | None, start: float,
                   title: str) -> Playback:
        def connect():
            casts, browser = pychromecast.get_listed_chromecasts(uuids=[device.config.uuid], discovery_timeout=6,
                                                                 known_hosts=self.manual_hosts or None)
            if not casts:
                pychromecast.discovery.stop_discovery(browser)
                raise LookupError(f"Couldn't connect to {device.name}.")
            cast = casts[0]
            cast.wait(timeout=10)
            controller = cast.media_controller
            controller.play_media(
                master_url, "application/x-mpegURL", title=title, current_time=start, stream_type="BUFFERED",
                subtitles=subtitles_url, subtitles_lang="en", subtitles_mime="text/vtt",
            )
            controller.block_until_active(timeout=15)
            return cast, browser

        cast, browser = await asyncio.to_thread(connect)
        return Playback(device, start, cast, browser)
