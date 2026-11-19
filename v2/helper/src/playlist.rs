//! HLS playlist helpers: routing every URI through the local proxy and swapping in our subtitle track.

use regex::Regex;
use std::sync::OnceLock;
use url::Url;

pub const MIME: &str = "application/vnd.apple.mpegurl";
pub const SUBTITLE_GROUP: &str = "softsubs";

pub fn is_master(text: &str) -> bool {
    text.contains("#EXT-X-STREAM-INF")
}

fn starts_with_header(data: &[u8], window: usize) -> bool {
    let start = String::from_utf8_lossy(&data[..data.len().min(window)]);
    start.trim_start_matches('\u{feff}').trim_start().starts_with("#EXTM3U")
}

pub fn looks_like_playlist(data: &[u8], content_type: &str, url: &Url) -> bool {
    if content_type.to_ascii_lowercase().contains("mpegurl") {
        return true;
    }
    let path = url.path().to_ascii_lowercase();
    if path.ends_with(".m3u8") || path.ends_with(".m3u") {
        return true;
    }
    starts_with_header(data, 16)
}

/// Some sites send playlists encrypted and decrypt them in their own player. Anything that claims to be a
/// playlist but doesn't start with #EXTM3U can't be played by a TV, so say so plainly.
pub fn unreadable_reason(data: &[u8], host: Option<&str>) -> Option<String> {
    if starts_with_header(data, 32) {
        return None;
    }
    Some(format!(
        "{} sends its playlist encrypted, so only its own player can read it. It can't be cast",
        host.unwrap_or("This site")
    ))
}

pub fn lines(text: &str) -> Vec<&str> {
    text.split('\n').map(|line| line.strip_suffix('\r').unwrap_or(line)).collect()
}

/// Resolves a playlist reference against the playlist's own URL (works for http and file URLs).
pub fn absolute(reference: &str, base: &Url) -> Option<Url> {
    base.join(reference).ok()
}

fn proxiable(reference: &str, base: &Url) -> Option<Url> {
    let url = absolute(reference, base)?;
    matches!(url.scheme(), "http" | "https").then_some(url)
}

// MARK: Rewriting

fn uri_attribute() -> &'static Regex {
    static PATTERN: OnceLock<Regex> = OnceLock::new();
    PATTERN.get_or_init(|| Regex::new(r#"URI="([^"]*)""#).unwrap())
}

/// Rewrites every segment, playlist and key URI so the TV fetches it through `proxy`.
pub fn rewrite(text: &str, base: &Url, proxy: impl Fn(&Url) -> String) -> String {
    lines(text)
        .into_iter()
        .map(|line| {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                String::new()
            } else if trimmed.starts_with('#') {
                // FairPlay (skd://) and data: URIs aren't http(s), so they're left alone.
                uri_attribute()
                    .replace_all(trimmed, |captures: &regex::Captures| match proxiable(&captures[1], base) {
                        Some(url) => format!("URI=\"{}\"", proxy(&url)),
                        None => captures[0].to_string(),
                    })
                    .into_owned()
            } else {
                proxiable(trimmed, base).map(|url| proxy(&url)).unwrap_or_else(|| trimmed.to_string())
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Adds `#EXT-X-START` so players begin at `start` seconds without being asked to seek. In a master
/// playlist the variant URIs (our proxy paths) carry the start on, so each media playlist gets the tag too.
pub fn starting_at(text: &str, start: f64, is_master: bool) -> String {
    let tag = format!("#EXT-X-START:TIME-OFFSET={start:.3},PRECISE=YES");
    let mut output = Vec::new();
    let mut after_stream_inf = false;
    for line in lines(text) {
        if line.starts_with("#EXT-X-START:") {
            continue;
        }
        if is_master && after_stream_inf && !line.is_empty() && !line.starts_with('#') {
            let separator = if line.contains('?') { '&' } else { '?' };
            output.push(format!("{line}{separator}start={start:.3}"));
            after_stream_inf = false;
            continue;
        }
        after_stream_inf = after_stream_inf || line.starts_with("#EXT-X-STREAM-INF");
        output.push(line.to_string());
        if line.starts_with("#EXTM3U") {
            output.push(tag.clone());
        }
    }
    output.join("\n")
}

// MARK: Subtitles

pub fn subtitle_media(name: &str, language: &str, uri: &str) -> String {
    let name = name.replace('"', "'");
    let language = language_tag(language).or_else(|| language_tag(&name)).unwrap_or_else(|| "und".to_string());
    format!(
        "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"{SUBTITLE_GROUP}\",NAME=\"{name}\",LANGUAGE=\"{language}\",\
         DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,URI=\"{uri}\""
    )
}

const LANGUAGES: &[(&str, &str)] = &[
    ("english", "en"), ("spanish", "es"), ("español", "es"), ("french", "fr"), ("français", "fr"),
    ("german", "de"), ("deutsch", "de"), ("italian", "it"), ("portuguese", "pt"), ("japanese", "ja"),
    ("korean", "ko"), ("chinese", "zh"), ("mandarin", "zh"), ("cantonese", "zh"), ("arabic", "ar"),
    ("russian", "ru"), ("hindi", "hi"), ("indonesian", "id"), ("malay", "ms"), ("thai", "th"),
    ("vietnamese", "vi"), ("turkish", "tr"), ("polish", "pl"), ("dutch", "nl"), ("swedish", "sv"),
    ("norwegian", "no"), ("danish", "da"), ("finnish", "fi"), ("greek", "el"), ("hebrew", "he"),
    ("czech", "cs"), ("hungarian", "hu"), ("romanian", "ro"), ("ukrainian", "uk"), ("filipino", "fil"),
    ("tagalog", "tl"), ("bengali", "bn"), ("tamil", "ta"), ("telugu", "te"), ("urdu", "ur"),
    ("persian", "fa"), ("croatian", "hr"), ("serbian", "sr"), ("bulgarian", "bg"), ("slovak", "sk"),
];

/// A BCP 47 tag for values like "en", "pt-BR", "English" or "CR English", so the TV can name the track.
pub fn language_tag(value: &str) -> Option<String> {
    static TAG: OnceLock<Regex> = OnceLock::new();
    let trimmed = value.trim();
    if TAG.get_or_init(|| Regex::new(r"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$").unwrap()).is_match(trimmed) {
        return Some(trimmed.to_string());
    }
    let lower = trimmed.to_lowercase();
    let words: Vec<&str> = lower.split(|c: char| !c.is_alphabetic()).filter(|w| !w.is_empty()).collect();
    LANGUAGES.iter().find(|(name, _)| words.contains(name)).map(|(_, code)| code.to_string())
}

/// Removes the stream's own subtitle renditions and points every variant at `media` instead.
pub fn replacing_subtitles(master: &str, media: Option<&str>) -> String {
    let mut output: Vec<String> = Vec::new();
    for line in lines(master) {
        if let Some(rest) = line.strip_prefix("#EXT-X-MEDIA:") {
            if attributes(rest).iter().any(|(key, value)| key == "TYPE" && value == "SUBTITLES") {
                continue;
            }
        }
        if let Some(rest) = line.strip_prefix("#EXT-X-STREAM-INF:") {
            let mut attrs: Vec<(String, String)> = attributes(rest).into_iter().filter(|(key, _)| key != "SUBTITLES").collect();
            if media.is_some() {
                attrs.push(("SUBTITLES".into(), format!("\"{SUBTITLE_GROUP}\"")));
            }
            let list: Vec<String> = attrs.iter().map(|(key, value)| format!("{key}={value}")).collect();
            output.push(format!("#EXT-X-STREAM-INF:{}", list.join(",")));
            continue;
        }
        output.push(line.to_string());
        if line.starts_with("#EXTM3U") {
            if let Some(media) = media {
                output.push(media.to_string());
            }
        }
    }
    output.join("\n")
}

/// A master playlist for a source that only has a single media playlist (or our own remux).
pub fn synthetic_master(media_uri: &str, subtitles: Option<&str>) -> String {
    let mut output = vec!["#EXTM3U".to_string()];
    if let Some(media) = subtitles {
        output.push(media.to_string());
    }
    let group = if subtitles.is_some() { format!(",SUBTITLES=\"{SUBTITLE_GROUP}\"") } else { String::new() };
    output.push(format!("#EXT-X-STREAM-INF:BANDWIDTH=5000000{group}"));
    output.push(media_uri.to_string());
    output.join("\n") + "\n"
}

/// Splits an attribute list such as `BANDWIDTH=1,CODECS="a,b"` into ordered key/value pairs.
pub fn attributes(list: &str) -> Vec<(String, String)> {
    let mut pairs = Vec::new();
    let mut current = String::new();
    let mut in_quotes = false;
    let flush = |current: &str, pairs: &mut Vec<(String, String)>| {
        if let Some((key, value)) = current.split_once('=') {
            pairs.push((key.to_string(), value.to_string()));
        }
    };
    for character in list.chars() {
        if character == '"' {
            in_quotes = !in_quotes;
        }
        if character == ',' && !in_quotes {
            flush(&current, &mut pairs);
            current.clear();
        } else {
            current.push(character);
        }
    }
    flush(&current, &mut pairs);
    pairs
}

// MARK: Inspection

pub fn first_variant(master: &str, base: &Url) -> Option<Url> {
    let all = lines(master);
    let index = all.iter().position(|line| line.starts_with("#EXT-X-STREAM-INF"))?;
    let uri = all[index + 1..].iter().find(|line| !line.is_empty() && !line.starts_with('#'))?;
    absolute(uri.trim(), base)
}

pub fn first_segment(media: &str, base: &Url) -> Option<Url> {
    let uri = lines(media).into_iter().find(|line| !line.is_empty() && !line.starts_with('#'))?;
    absolute(uri.trim(), base)
}

fn unquote(value: &str) -> &str {
    value.trim_matches('"')
}

/// The init section's URL and its `Range` header value, if it's a byte range.
pub fn init_section(media: &str, base: &Url) -> Option<(Url, Option<String>)> {
    let line = lines(media).into_iter().find(|line| line.starts_with("#EXT-X-MAP:"))?;
    let attrs = attributes(&line["#EXT-X-MAP:".len()..]);
    let uri = attrs.iter().find(|(key, _)| key == "URI")?;
    let url = absolute(unquote(&uri.1), base)?;
    let range = attrs.iter().find(|(key, _)| key == "BYTERANGE").and_then(|(_, value)| range_header(unquote(value)));
    Some((url, range))
}

/// The `Range` header for the first segment when the playlist uses `#EXT-X-BYTERANGE`.
pub fn first_segment_range(media: &str) -> Option<String> {
    let mut range = None;
    for line in lines(media) {
        if let Some(value) = line.strip_prefix("#EXT-X-BYTERANGE:") {
            range = range_header(value);
        }
        if !line.is_empty() && !line.starts_with('#') {
            break;
        }
    }
    range
}

/// Converts an HLS byte range (`length@offset`) into an HTTP `Range` value.
fn range_header(value: &str) -> Option<String> {
    let mut parts = value.trim().split('@');
    let length: u64 = parts.next()?.parse().ok().filter(|&length| length > 0)?;
    let offset: u64 = parts.next().and_then(|offset| offset.parse().ok()).unwrap_or(0);
    Some(format!("bytes={}-{}", offset, offset + length - 1))
}

fn extinf_duration(line: &str) -> Option<f64> {
    let value = line.strip_prefix("#EXTINF:")?;
    value.split(',').next()?.trim().parse().ok()
}

pub fn total_duration(media: &str) -> f64 {
    lines(media).into_iter().filter_map(extinf_duration).sum()
}

/// A media playlist's segments in play order, with their durations. Byte-range segments are left out:
/// they're fetched with a Range header, which the segment cache doesn't handle.
pub fn segments(media: &str, base: &Url) -> Vec<(Url, f64)> {
    let mut result = Vec::new();
    let mut duration = None;
    let mut byte_range = false;
    for line in lines(media) {
        let trimmed = line.trim();
        if trimmed.starts_with("#EXTINF:") {
            duration = extinf_duration(trimmed);
        } else if trimmed.starts_with("#EXT-X-BYTERANGE:") {
            byte_range = true;
        } else if !trimmed.is_empty() && !trimmed.starts_with('#') {
            if let (Some(duration), false, Some(url)) = (duration, byte_range, proxiable(trimmed, base)) {
                result.push((url, duration));
            }
            duration = None;
            byte_range = false;
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base() -> Url {
        Url::parse("https://cdn.example/show/master.m3u8?token=1").unwrap()
    }

    #[test]
    fn rewrites_uris_and_attributes() {
        let text = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXTINF:4,\nseg1.ts\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://x\"\n";
        let out = rewrite(text, &base(), |url| format!("P({url})"));
        assert!(out.contains("URI=\"P(https://cdn.example/show/key.bin)\""));
        assert!(out.contains("\nP(https://cdn.example/show/seg1.ts)"));
        assert!(out.contains("URI=\"skd://x\""));
    }

    #[test]
    fn replaces_subtitles() {
        let master = "#EXTM3U\n#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"s\",URI=\"x\"\n#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS=\"a,b\",SUBTITLES=\"s\"\nv.m3u8";
        let out = replacing_subtitles(master, Some("#EXT-X-MEDIA:OURS"));
        assert_eq!(out, "#EXTM3U\n#EXT-X-MEDIA:OURS\n#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS=\"a,b\",SUBTITLES=\"softsubs\"\nv.m3u8");
    }

    #[test]
    fn language_tags() {
        assert_eq!(language_tag("pt-BR").as_deref(), Some("pt-BR"));
        assert_eq!(language_tag("CR English").as_deref(), Some("en"));
        assert_eq!(language_tag("Klingon subs"), None);
    }

    #[test]
    fn segments_and_durations() {
        let media = "#EXTM3U\n#EXTINF:4.5,\na.jpg\n#EXTINF:3,\n#EXT-X-BYTERANGE:100@0\nb.ts\n#EXTINF:2,\nc.css\n";
        let found = segments(media, &base());
        assert_eq!(found.len(), 2);
        assert_eq!(found[0].0.as_str(), "https://cdn.example/show/a.jpg");
        assert_eq!(total_duration(media), 9.5);
    }

    #[test]
    fn encrypted_playlist_is_reported() {
        assert!(unreadable_reason(b"\xef\xbb\xbf#EXTM3U\n", None).is_none());
        assert!(unreadable_reason(b"U2FsdGVkX1+abc", Some("fetch8.example")).unwrap().starts_with("fetch8.example"));
    }

    #[test]
    fn start_tag_and_variants() {
        let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\n/s/x/p?u=a\n#EXT-X-MEDIA:TYPE=SUBTITLES,URI=\"/s/x/subs.m3u8\"";
        let out = starting_at(master, 125.5, true);
        assert_eq!(out, "#EXTM3U\n#EXT-X-START:TIME-OFFSET=125.500,PRECISE=YES\n#EXT-X-STREAM-INF:BANDWIDTH=1\n/s/x/p?u=a&start=125.500\n#EXT-X-MEDIA:TYPE=SUBTITLES,URI=\"/s/x/subs.m3u8\"");
        let media = starting_at("#EXTM3U\n#EXTINF:4,\n/s/x/p?u=b", 10.0, false);
        assert_eq!(media, "#EXTM3U\n#EXT-X-START:TIME-OFFSET=10.000,PRECISE=YES\n#EXTINF:4,\n/s/x/p?u=b");
    }

    #[test]
    fn byte_ranges() {
        assert_eq!(first_segment_range("#EXT-X-BYTERANGE:100@50\nseg.mp4").as_deref(), Some("bytes=50-149"));
        let (url, range) = init_section("#EXT-X-MAP:URI=\"init.mp4\",BYTERANGE=\"10@0\"", &base()).unwrap();
        assert_eq!(url.as_str(), "https://cdn.example/show/init.mp4");
        assert_eq!(range.as_deref(), Some("bytes=0-9"));
    }
}
