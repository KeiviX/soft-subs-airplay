"""Finding TVs and sending the rebuilt stream to them.

Windows has no AirPlay of its own, so this speaks to the TV directly:
- AirPlay via pyatv (Apple TV and AirPlay 2 TVs; most TVs need a one-time PIN pairing)
- Chromecast via pychromecast (Google TV / Android TV sets and Chromecast dongles)
"""

from __future__ import annotations

import asyncio
import ipaddress
import json
import time
from dataclasses import dataclass, field
from typing import Any

import pyatv
import pychromecast
from pyatv.const import PairingRequirement, Protocol
from pyatv.storage.file_storage import FileStorage

from .log import DATA_DIR, log


@dataclass
class Device:
    id: str
    name: str
    kind: str  # "airplay" | "chromecast"
    address: str
    needs_pairing: bool = False
    paired: bool = False
    config: Any = field(default=None, repr=False)

    def public(self) -> dict:
        return {"id": self.id, "name": self.name, "kind": self.kind, "address": self.address,
                "needsPairing": self.needs_pairing and not self.paired}


class Playback:
    """A stream playing on a TV. `position` is estimated from when playback started."""

    def __init__(self, device: Device, start: float) -> None:
        self.device = device
        self._start = start
        self._started_at = time.monotonic()
        self.paused_at: float | None = None

    @property
    def position(self) -> float:
        return self._start + (time.monotonic() - self._started_at)

    async def set_subtitles(self, on: bool) -> bool:
        """Turns subtitles on/off without restarting, if the receiver supports it."""
        return False

    async def stop(self) -> None:
        pass


class AirPlayPlayback(Playback):
    def __init__(self, device: Device, start: float, atv, task: asyncio.Task) -> None:
        super().__init__(device, start)
        self.atv = atv
        self.task = task

    async def stop(self) -> None:
        self.task.cancel()
        self.atv.close()


class CastPlayback(Playback):
    def __init__(self, device: Device, start: float, cast, browser) -> None:
        super().__init__(device, start)
        self.cast = cast
        self.browser = browser

    @property
    def position(self) -> float:
        status = self.cast.media_controller.status
        return status.adjusted_current_time if status and status.adjusted_current_time else super().position

    async def set_subtitles(self, on: bool) -> bool:
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
        self._storage: FileStorage | None = None
        self._pairings: dict[str, Any] = {}
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
            raise LookupError(f"No AirPlay or Chromecast TV answered at {address}. Is it on, and is the address right?")
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        self._hosts_file.write_text(json.dumps(self.manual_hosts), encoding="utf-8")
        return devices

    async def storage(self) -> FileStorage:
        if self._storage is None:
            DATA_DIR.mkdir(parents=True, exist_ok=True)
            self._storage = FileStorage(str(DATA_DIR / "pairings.json"), asyncio.get_running_loop())
            await self._storage.load()
        return self._storage

    @property
    def scanning(self) -> bool:
        return self._scan_lock.locked()

    def scan_in_background(self) -> None:
        if not self.scanning:
            asyncio.get_running_loop().create_task(self.scan())

    async def scan(self) -> list[Device]:
        async with self._scan_lock:
            found: dict[str, Device] = {}
            scans = [self._scan_airplay(), asyncio.to_thread(self._scan_chromecast, self.manual_hosts)]
            if self.manual_hosts:
                scans.append(self._scan_airplay(self.manual_hosts))  # Unicast: works without multicast.
            for result in await asyncio.gather(*scans, return_exceptions=True):
                if isinstance(result, Exception):
                    log(f"scan failed: {result!r}")
                    continue
                for device in result:
                    found[device.id] = device
            # AirPlay first: it's the main route; Chromecast is the fallback for TVs that refuse AirPlay.
            self.devices = dict(sorted(found.items(), key=lambda item: (item[1].kind != "airplay", item[1].name)))
            log(f"devices: {[f'{d.name} ({d.kind})' for d in found.values()]}")
            return list(found.values())

    async def _scan_airplay(self, hosts: list[str] | None = None) -> list[Device]:
        configs = await pyatv.scan(asyncio.get_running_loop(), timeout=4, protocol=Protocol.AirPlay, hosts=hosts,
                                   storage=await self.storage())
        devices = []
        for config in configs:
            service = config.get_service(Protocol.AirPlay)
            if service is None or (config.device_info.operating_system.name == "MacOS"):
                continue  # Macs advertise AirPlay as receivers too; they're not TVs.
            devices.append(Device(
                id=f"airplay:{config.identifier}", name=config.name, kind="airplay", address=str(config.address),
                needs_pairing=service.pairing == PairingRequirement.Mandatory,
                paired=service.credentials is not None, config=config,
            ))
        return devices

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

    # Pairing (AirPlay)

    async def begin_pairing(self, device_id: str) -> None:
        device = await self.device(device_id)
        pairing = await pyatv.pair(device.config, Protocol.AirPlay, asyncio.get_running_loop(),
                                   storage=await self.storage(), name="Soft Subs")
        await pairing.begin()
        self._pairings[device_id] = pairing
        log(f"pairing started with {device.name}")

    async def finish_pairing(self, device_id: str, pin: str) -> bool:
        pairing = self._pairings.pop(device_id, None)
        if pairing is None:
            raise LookupError("Start pairing first.")
        try:
            pairing.pin(int(pin))
            await pairing.finish()
            paired = pairing.has_paired
        finally:
            await pairing.close()
        if paired:
            await (await self.storage()).save()
            await self.scan()
        log(f"pairing finished: {paired}")
        return paired

    # Playback

    async def play(self, device: Device, master_url: str, subtitles_url: str | None, start: float, title: str,
                   on_finished) -> Playback:
        if device.kind == "airplay":
            return await self._play_airplay(device, master_url, start, on_finished)
        return await self._play_chromecast(device, master_url, subtitles_url, start, title)

    async def _play_airplay(self, device: Device, url: str, start: float, on_finished) -> Playback:
        if device.needs_pairing and not device.paired:
            raise PermissionError(f"Pair with {device.name} first (it shows a PIN on screen).")
        atv = await pyatv.connect(device.config, asyncio.get_running_loop(), protocol=Protocol.AirPlay,
                                  storage=await self.storage())
        task = asyncio.create_task(atv.stream.play_url(url, position=start))

        def finished(task: asyncio.Task) -> None:
            error = None if task.cancelled() else task.exception()
            log(f"airplay playback ended: {error!r}")
            on_finished(error)

        # play_url only returns when playback ends; give it a moment to fail fast (refused, bad pairing...).
        done, _ = await asyncio.wait({task}, timeout=4)
        if done and task.exception():
            atv.close()
            raise task.exception()
        task.add_done_callback(finished)
        return AirPlayPlayback(device, start, atv, task)

    async def _play_chromecast(self, device: Device, url: str, subtitles_url: str | None, start: float,
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
                url, "application/x-mpegURL", title=title, current_time=start, stream_type="BUFFERED",
                subtitles=subtitles_url, subtitles_lang="en", subtitles_mime="text/vtt",
            )
            controller.block_until_active(timeout=15)
            return cast, browser

        cast, browser = await asyncio.to_thread(connect)
        return CastPlayback(device, start, cast, browser)
