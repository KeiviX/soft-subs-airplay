from softsubs import hls, media

MASTER = """#EXTM3U
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",URI="subs/en.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Main",URI="audio/main.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="avc1.4d401e,mp4a.40.2",AUDIO="aud",SUBTITLES="subs"
low/index.m3u8
#EXT-X-STREAM-INF:SUBTITLES="subs",BANDWIDTH=2800000
https://cdn.example.com/high/index.m3u8
"""


def proxy(url: str) -> str:
    return f"/p?u={url}"


def test_rewrite_routes_every_uri_through_the_proxy():
    text = hls.rewrite(MASTER, "https://host.example/show/master.m3u8", proxy)
    assert "/p?u=https://host.example/show/low/index.m3u8" in text
    assert "/p?u=https://cdn.example.com/high/index.m3u8" in text
    assert 'URI="/p?u=https://host.example/show/audio/main.m3u8"' in text


def test_rewrite_leaves_fairplay_keys_alone():
    text = hls.rewrite('#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://key"\nseg.ts', "https://h.example/a.m3u8", proxy)
    assert 'URI="skd://key"' in text


def test_replacing_subtitles_swaps_in_our_rendition():
    media_line = hls.subtitle_media("CR English", "", "/subs.m3u8")
    text = hls.replacing_subtitles(MASTER, media_line)
    assert 'GROUP-ID="subs"' not in text
    assert 'LANGUAGE="en"' in media_line
    variants = [line for line in text.splitlines() if line.startswith("#EXT-X-STREAM-INF")]
    assert all(line.count("SUBTITLES=") == 1 and 'SUBTITLES="softsubs"' in line for line in variants)
    assert 'CODECS="avc1.4d401e,mp4a.40.2"' in variants[0]


def test_byte_ranges_and_init_sections():
    media_playlist = '#EXT-X-MAP:URI="init.mp4",BYTERANGE="720@0"\n#EXTINF:4,\n#EXT-X-BYTERANGE:1000@720\nmain.mp4\n'
    assert hls.init_section(media_playlist, "https://h.example/v/index.m3u8") == ("https://h.example/v/init.mp4", "bytes=0-719")
    assert hls.first_segment_range(media_playlist) == "bytes=720-1719"
    assert hls.total_duration("#EXTINF:4.5,\na\n#EXTINF:5.5,\nb") == 10


def test_subtitle_segments_carry_the_timestamp_map():
    cues = [hls.Cue(1, 4, "first"), hls.Cue(61, 64, "<i>second</i>\n\nline")]
    first = hls.subtitle_segment(0, cues, 0.5, 900000)
    assert "X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000" in first
    assert "00:00:01.500 --> 00:00:04.500\nfirst" in first and "second" not in first
    assert "<i>second</i>\nline" in hls.subtitle_segment(1, cues, 0, 0)
    assert "X-TIMESTAMP-MAP" not in hls.subtitle_file(cues, 0)


def test_unwrap_ts_finds_disguised_segments():
    ts = bytes([0x47] + [0] * 187) * 10
    assert media.unwrap_ts(ts) == ts
    assert media.unwrap_ts(b"\x89PNG fake header" + ts) == ts
    assert media.unwrap_ts(b"\x00\x00\x00\x18ftypmp42" + b"\x00" * 1000) is None
