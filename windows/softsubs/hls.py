"""HLS playlist and WebVTT helpers: routing every URI through the local proxy and swapping in our subtitle track.

A port of App/Playlist.swift and App/WebVTT.swift from the macOS app; keep the two in step.
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass
from typing import Callable
from urllib.parse import urljoin, urlsplit

MIME = "application/vnd.apple.mpegurl"
SUBTITLE_GROUP = "softsubs"
SEGMENT_LENGTH = 60.0


@dataclass
class Cue:
    start: float
    end: float
    text: str


def lines(text: str) -> list[str]:
    return text.replace("\r\n", "\n").split("\n")


def is_master(text: str) -> bool:
    return "#EXT-X-STREAM-INF" in text


def looks_like_playlist(data: bytes, content_type: str, url: str) -> bool:
    if "mpegurl" in content_type.lower():
        return True
    if urlsplit(url).path.lower().endswith((".m3u8", ".m3u")):
        return True
    return data[:16].lstrip(b"\xef\xbb\xbf \t\r\n").startswith(b"#EXTM3U")


def absolute(reference: str, base: str) -> str:
    return urljoin(base, reference.strip())


def _proxiable(reference: str, base: str) -> str | None:
    url = absolute(reference, base)
    return url if urlsplit(url).scheme in ("http", "https") else None


_URI_ATTRIBUTE = re.compile(r'URI="([^"]*)"')


def rewrite(text: str, base: str, proxy: Callable[[str], str]) -> str:
    """Rewrites every segment, playlist and key URI so the TV fetches it through `proxy`.
    FairPlay (skd://) and data: URIs are left alone."""

    def attribute(match: re.Match) -> str:
        url = _proxiable(match.group(1), base)
        return f'URI="{proxy(url)}"' if url else match.group(0)

    output = []
    for line in lines(text):
        stripped = line.strip()
        if not stripped:
            output.append("")
        elif stripped.startswith("#"):
            output.append(_URI_ATTRIBUTE.sub(attribute, stripped))
        else:
            url = _proxiable(stripped, base)
            output.append(proxy(url) if url else stripped)
    return "\n".join(output)


def attributes(attribute_list: str) -> list[tuple[str, str]]:
    """Splits `BANDWIDTH=1,CODECS="a,b"` into ordered key/value pairs."""
    pairs, current, in_quotes = [], "", False
    for character in attribute_list + ",":
        if character == '"':
            in_quotes = not in_quotes
        if character == "," and not in_quotes:
            if "=" in current:
                key, value = current.split("=", 1)
                pairs.append((key, value))
            current = ""
        else:
            current += character
    return pairs


_LANGUAGES = {
    "english": "en", "spanish": "es", "portuguese": "pt", "french": "fr", "german": "de", "italian": "it",
    "japanese": "ja", "chinese": "zh", "korean": "ko", "arabic": "ar", "russian": "ru", "hindi": "hi",
    "turkish": "tr", "polish": "pl", "dutch": "nl", "swedish": "sv", "norwegian": "no", "danish": "da",
    "finnish": "fi", "greek": "el", "hebrew": "he", "thai": "th", "vietnamese": "vi", "indonesian": "id",
    "malay": "ms", "ukrainian": "uk", "czech": "cs", "romanian": "ro", "hungarian": "hu", "albanian": "sq",
}


def language_tag(value: str) -> str | None:
    """A BCP 47 tag for values like "en", "pt-BR", "English" or "CR English", so the TV can name the track."""
    value = value.strip()
    if re.fullmatch(r"[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*", value):
        return value
    for word in re.findall(r"[a-z]+", value.lower()):
        if word in _LANGUAGES:
            return _LANGUAGES[word]
    return None


def subtitle_media(name: str, language: str, uri: str) -> str:
    name = name.replace('"', "'")
    tag = language_tag(language) or language_tag(name) or "und"
    return (f'#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="{SUBTITLE_GROUP}",NAME="{name}",LANGUAGE="{tag}",'
            f'DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,URI="{uri}"')


def replacing_subtitles(master: str, media: str | None) -> str:
    """Removes the stream's own subtitle renditions and points every variant at `media` instead."""
    output = []
    for line in lines(master):
        if line.startswith("#EXT-X-MEDIA:") and ("TYPE", "SUBTITLES") in attributes(line[13:]):
            continue
        if line.startswith("#EXT-X-STREAM-INF:"):
            attrs = [pair for pair in attributes(line[18:]) if pair[0] != "SUBTITLES"]
            if media:
                attrs.append(("SUBTITLES", f'"{SUBTITLE_GROUP}"'))
            output.append("#EXT-X-STREAM-INF:" + ",".join(f"{k}={v}" for k, v in attrs))
            continue
        output.append(line)
        if line.startswith("#EXTM3U") and media:
            output.append(media)
    return "\n".join(output)


def synthetic_master(media_uri: str, subtitles: str | None) -> str:
    """A master playlist for a source that only has a single media playlist (or our own remux)."""
    output = ["#EXTM3U"]
    if subtitles:
        output.append(subtitles)
    output.append("#EXT-X-STREAM-INF:BANDWIDTH=5000000" + (f',SUBTITLES="{SUBTITLE_GROUP}"' if subtitles else ""))
    output.append(media_uri)
    return "\n".join(output) + "\n"


def first_variant(master: str, base: str) -> str | None:
    all_lines = lines(master)
    for index, line in enumerate(all_lines):
        if line.startswith("#EXT-X-STREAM-INF"):
            for candidate in all_lines[index + 1:]:
                if candidate.strip() and not candidate.startswith("#"):
                    return absolute(candidate, base)
    return None


def first_segment(media: str, base: str) -> str | None:
    for line in lines(media):
        if line.strip() and not line.startswith("#"):
            return absolute(line, base)
    return None


def _range_header(value: str) -> str | None:
    parts = value.strip().strip('"').split("@")
    try:
        length = int(parts[0])
        offset = int(parts[1]) if len(parts) > 1 else 0
    except ValueError:
        return None
    return f"bytes={offset}-{offset + length - 1}" if length > 0 else None


def init_section(media: str, base: str) -> tuple[str, str | None] | None:
    """The init section's URL and its Range header value, if it's a byte range."""
    for line in lines(media):
        if line.startswith("#EXT-X-MAP:"):
            attrs = dict(attributes(line[11:]))
            if "URI" not in attrs:
                return None
            byte_range = attrs.get("BYTERANGE")
            return absolute(attrs["URI"].strip('"'), base), _range_header(byte_range) if byte_range else None
    return None


def first_segment_range(media: str) -> str | None:
    """The Range header for the first segment when the playlist uses #EXT-X-BYTERANGE."""
    byte_range = None
    for line in lines(media):
        if line.startswith("#EXT-X-BYTERANGE:"):
            byte_range = _range_header(line[17:])
        if line.strip() and not line.startswith("#"):
            break
    return byte_range


def total_duration(media: str) -> float:
    total = 0.0
    for line in lines(media):
        if line.startswith("#EXTINF:"):
            try:
                total += float(line[8:].split(",")[0])
            except ValueError:
                pass
    return total


# WebVTT


def timestamp(seconds: float) -> str:
    ms = int(round(seconds * 1000))
    return f"{ms // 3_600_000:02d}:{ms // 60_000 % 60:02d}:{ms // 1000 % 60:02d}.{ms % 1000:03d}"


def _sanitize(text: str) -> str:
    """Keeps cue text valid WebVTT: no blank lines (they end a cue) and no stray arrows."""
    return "\n".join(line.strip() for line in text.replace("-->", "→").splitlines() if line.strip())


def subtitle_playlist(duration: float, uri: Callable[[int], str]) -> str:
    count = max(1, math.ceil(duration / SEGMENT_LENGTH))
    output = ["#EXTM3U", "#EXT-X-VERSION:3", f"#EXT-X-TARGETDURATION:{int(SEGMENT_LENGTH)}",
              "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD"]
    for index in range(count):
        length = min(SEGMENT_LENGTH, duration - index * SEGMENT_LENGTH)
        output += [f"#EXTINF:{max(length, 0.001):.3f},", uri(index)]
    output.append("#EXT-X-ENDLIST")
    return "\n".join(output) + "\n"


def _cue_lines(cues: list[Cue], offset: float, start: float, end: float) -> str:
    output = ""
    for cue in cues:
        cue_start, cue_end, text = max(0.0, cue.start + offset), cue.end + offset, _sanitize(cue.text)
        if cue_end > cue_start and cue_end > start and cue_start < end and text:
            output += f"\n{timestamp(cue_start)} --> {timestamp(cue_end)}\n{text}\n"
    return output


def subtitle_segment(index: int, cues: list[Cue], offset: float, timestamp_base: int) -> str:
    """One segment's cues. `timestamp_base` is the media's first presentation timestamp (90 kHz), which is
    what the browser's currentTime == 0 corresponds to, so cue times line up with the video."""
    start = index * SEGMENT_LENGTH
    header = f"WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:{timestamp_base},LOCAL:00:00:00.000\n"
    return header + _cue_lines(cues, offset, start, start + SEGMENT_LENGTH)


def subtitle_file(cues: list[Cue], offset: float) -> str:
    """All cues as one sidecar file, for Chromecast (its player already normalises time to start at 0)."""
    return "WEBVTT\n" + _cue_lines(cues, offset, 0, math.inf)
