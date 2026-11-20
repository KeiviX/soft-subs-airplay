//! Casting to DLNA (UPnP) TVs, such as Samsung's: finding them with SSDP and driving their AVTransport.
//!
//! A DLNA TV can't play HLS, so the helper gives it one continuous MPEG-TS stream (see `server.rs`), and
//! subtitles as an .srt file through Samsung's caption extension (`sec:CaptionInfoEx` / `CaptionInfo.sec`).

use regex::Regex;
use std::collections::HashMap;
use std::net::SocketAddr;
use std::time::Duration;
use tokio::net::UdpSocket;
use url::Url;

use crate::log;

#[derive(Clone, Debug)]
pub struct Renderer {
    /// `dlna:` plus the device's UDN.
    pub id: String,
    pub name: String,
    pub av_transport: Url,
}

/// Streaming, time-seekable (DLNA.ORG_OP=10), not a converted original.
pub const CONTENT_FEATURES: &str = "DLNA.ORG_OP=10;DLNA.ORG_CI=1;DLNA.ORG_FLAGS=01700000000000000000000000000000";
/// MPEG-TS, with subtitles (if any) as a separate .srt through Samsung's caption extension.
pub const TS_MIME: &str = "video/mpeg";
/// Matroska, with the subtitles inside as a default-on track. Samsung's Tizen player ignores external
/// subtitles on media pushed to it, but shows a subtitle track that's in the file.
pub const MKV_MIME: &str = "video/x-mkv";

/// Sends SSDP searches for media renderers and reads their device descriptions.
pub async fn discover(wait: Duration) -> Vec<Renderer> {
    let locations = match search(wait).await {
        Ok(locations) => locations,
        Err(error) => {
            log::log(format!("DLNA search failed: {error}"));
            return Vec::new();
        }
    };
    let client = reqwest::Client::builder().timeout(Duration::from_secs(4)).build().expect("HTTP client");
    let mut found: Vec<Renderer> = Vec::new();
    for location in locations {
        let Ok(text) = async { client.get(location.clone()).send().await?.text().await }.await else { continue };
        if let Some(renderer) = parse_description(&text, &location) {
            if !found.iter().any(|existing| existing.id == renderer.id) {
                found.push(renderer);
            }
        }
    }
    found
}

async fn search(wait: Duration) -> std::io::Result<Vec<Url>> {
    let socket = UdpSocket::bind("0.0.0.0:0").await?;
    socket.set_multicast_ttl_v4(2)?;
    let target: SocketAddr = "239.255.255.250:1900".parse().unwrap();
    let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\n\
                   ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n";
    for _ in 0..2 {
        socket.send_to(message.as_bytes(), target).await?;
    }
    let mut locations = Vec::new();
    let deadline = tokio::time::Instant::now() + wait;
    let mut buffer = vec![0u8; 8192];
    while let Ok(Ok((length, _))) = tokio::time::timeout_at(deadline, socket.recv_from(&mut buffer)).await {
        let text = String::from_utf8_lossy(&buffer[..length]);
        let location = text.lines().find_map(|line| {
            let (name, value) = line.split_once(':')?;
            name.trim().eq_ignore_ascii_case("location").then(|| value.trim().to_string())
        });
        if let Some(url) = location.and_then(|location| Url::parse(&location).ok()) {
            if !locations.contains(&url) {
                locations.push(url);
            }
        }
    }
    Ok(locations)
}

fn tag(text: &str, name: &str) -> Option<String> {
    let pattern = Regex::new(&format!(r"(?s)<{name}>(.*?)</{name}>")).ok()?;
    pattern.captures(text).map(|captures| captures[1].trim().to_string())
}

fn parse_description(text: &str, location: &Url) -> Option<Renderer> {
    let name = tag(text, "friendlyName")?;
    let udn = tag(text, "UDN").unwrap_or_else(|| location.to_string());
    let services = Regex::new(r"(?s)<service>(.*?)</service>").ok()?;
    let control = services
        .captures_iter(text)
        .map(|captures| captures[1].to_string())
        .find(|service| service.contains("service:AVTransport:"))
        .and_then(|service| tag(&service, "controlURL"))?;
    Some(Renderer { id: format!("dlna:{udn}"), name: xml_unescape(&name), av_transport: location.join(&control).ok()? })
}

// MARK: Control

async fn soap(renderer: &Renderer, action: &str, arguments: &[(&str, String)]) -> Result<String, String> {
    let service = "urn:schemas-upnp-org:service:AVTransport:1";
    let body: String = arguments.iter().map(|(name, value)| format!("<{name}>{}</{name}>", xml_escape(value))).collect();
    let envelope = format!(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\
         <s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">\
         <s:Body><u:{action} xmlns:u=\"{service}\"><InstanceID>0</InstanceID>{body}</u:{action}></s:Body></s:Envelope>"
    );
    let client = reqwest::Client::builder().timeout(Duration::from_secs(8)).build().map_err(|e| e.to_string())?;
    let response = client
        .post(renderer.av_transport.clone())
        .header("Content-Type", "text/xml; charset=\"utf-8\"")
        .header("SOAPACTION", format!("\"{service}#{action}\""))
        .body(envelope)
        .send()
        .await
        .map_err(|error| format!("{} didn't answer: {error}", renderer.name))?;
    let status = response.status();
    let text = response.text().await.unwrap_or_default();
    if !status.is_success() {
        let detail = tag(&text, "errorDescription").or_else(|| tag(&text, "errorCode")).unwrap_or_else(|| status.to_string());
        return Err(format!("{} refused {action}: {detail}", renderer.name));
    }
    Ok(text)
}

pub struct Media<'a> {
    pub url: &'a str,
    pub mime: &'a str,
    pub title: &'a str,
    pub duration: f64,
    pub subtitles: Option<&'a str>,
}

/// Loads `media` on the TV and starts it.
pub async fn play_media(renderer: &Renderer, media: &Media<'_>) -> Result<(), String> {
    // Some TVs refuse a new URI while something is loaded; stopping first is harmless when nothing is.
    let _ = soap(renderer, "Stop", &[]).await;
    soap(renderer, "SetAVTransportURI", &[("CurrentURI", media.url.to_string()), ("CurrentURIMetaData", didl(media))]).await?;
    play(renderer).await
}

pub async fn play(renderer: &Renderer) -> Result<(), String> {
    soap(renderer, "Play", &[("Speed", "1".into())]).await.map(|_| ())
}

pub async fn pause(renderer: &Renderer) -> Result<(), String> {
    soap(renderer, "Pause", &[]).await.map(|_| ())
}

pub async fn stop(renderer: &Renderer) -> Result<(), String> {
    soap(renderer, "Stop", &[]).await.map(|_| ())
}

pub async fn seek(renderer: &Renderer, seconds: f64) -> Result<(), String> {
    soap(renderer, "Seek", &[("Unit", "REL_TIME".into()), ("Target", clock(seconds))]).await.map(|_| ())
}

#[derive(Debug, Default)]
pub struct Position {
    pub time: f64,
    pub duration: f64,
    /// PLAYING, PAUSED_PLAYBACK, STOPPED, TRANSITIONING...
    pub state: String,
}

pub async fn position(renderer: &Renderer) -> Result<Position, String> {
    let info = soap(renderer, "GetPositionInfo", &[]).await?;
    let transport = soap(renderer, "GetTransportInfo", &[]).await?;
    Ok(Position {
        time: tag(&info, "RelTime").map(|t| parse_clock(&t)).unwrap_or(0.0),
        duration: tag(&info, "TrackDuration").map(|t| parse_clock(&t)).unwrap_or(0.0),
        state: tag(&transport, "CurrentTransportState").unwrap_or_default(),
    })
}

// MARK: Formats

fn didl(media: &Media<'_>) -> String {
    let duration = clock_ms(media.duration);
    let mut item = format!(
        "<dc:title>{}</dc:title><upnp:class>object.item.videoItem</upnp:class>\
         <res protocolInfo=\"http-get:*:{}:{CONTENT_FEATURES}\" duration=\"{duration}\">{}</res>",
        xml_escape(media.title),
        media.mime,
        xml_escape(media.url)
    );
    if let Some(subtitles) = media.subtitles {
        let url = xml_escape(subtitles);
        item += &format!(
            "<res protocolInfo=\"http-get:*:smi/caption:*\">{url}</res>\
             <sec:CaptionInfoEx sec:type=\"srt\">{url}</sec:CaptionInfoEx>\
             <sec:CaptionInfo sec:type=\"srt\">{url}</sec:CaptionInfo>"
        );
    }
    format!(
        "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" \
         xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" xmlns:dlna=\"urn:schemas-dlna-org:metadata-1-0/\" \
         xmlns:sec=\"http://www.sec.co.kr/\"><item id=\"0\" parentID=\"-1\" restricted=\"1\">{item}</item></DIDL-Lite>"
    )
}

/// `H:MM:SS` for Seek targets.
pub fn clock(seconds: f64) -> String {
    let total = seconds.max(0.0).round() as u64;
    format!("{}:{:02}:{:02}", total / 3600, total / 60 % 60, total % 60)
}

fn clock_ms(seconds: f64) -> String {
    let ms = (seconds.max(0.0) * 1000.0).round() as u64;
    format!("{}:{:02}:{:02}.{:03}", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
}

/// Parses `H:MM:SS(.fff)`; "NOT_IMPLEMENTED" and the like come out as 0.
pub fn parse_clock(value: &str) -> f64 {
    let parts: Vec<f64> = value.trim().split(':').filter_map(|part| part.parse().ok()).collect();
    if parts.len() != 3 {
        return 0.0;
    }
    parts[0] * 3600.0 + parts[1] * 60.0 + parts[2]
}

/// The start of a DLNA `TimeSeekRange.dlna.org` request header, e.g. `npt=123.4-` or `npt=0:02:03.4-`.
pub fn time_seek_start(header: &str) -> Option<f64> {
    let value = header.trim().strip_prefix("npt=")?;
    let start = value.split('-').next()?.trim();
    if start.contains(':') {
        Some(parse_clock(start))
    } else {
        start.parse().ok()
    }
}

fn xml_escape(value: &str) -> String {
    value.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

fn xml_unescape(value: &str) -> String {
    value.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&amp;", "&")
}

/// Known renderers, refreshed in the background so the extension can list TVs straight away.
#[derive(Default)]
pub struct Registry {
    pub renderers: HashMap<String, Renderer>,
    pub scanning: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_samsung_description() {
        let text = "<root><device><friendlyName>Samsung QN90BA 65</friendlyName><UDN>uuid:abc</UDN><serviceList>\
            <service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><controlURL>/upnp/control/RenderingControl1</controlURL></service>\
            <service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/upnp/control/AVTransport1</controlURL></service>\
            </serviceList></device></root>";
        let renderer = parse_description(text, &Url::parse("http://192.168.0.15:9197/dmr").unwrap()).unwrap();
        assert_eq!(renderer.id, "dlna:uuid:abc");
        assert_eq!(renderer.av_transport.as_str(), "http://192.168.0.15:9197/upnp/control/AVTransport1");
    }

    #[test]
    fn clocks_and_seek_headers() {
        assert_eq!(clock(3725.4), "1:02:05");
        assert_eq!(parse_clock("0:24:46.242"), 1486.242);
        assert_eq!(parse_clock("NOT_IMPLEMENTED"), 0.0);
        assert_eq!(time_seek_start("npt=123.5-"), Some(123.5));
        assert_eq!(time_seek_start("npt=0:02:03.5-0:24:00"), Some(123.5));
    }

    #[test]
    fn metadata_carries_subtitles() {
        let media = Media { url: "http://h/s/1/dlna.ts", mime: TS_MIME, title: "A & B", duration: 61.5, subtitles: Some("http://h/s/1/subs.srt") };
        let text = didl(&media);
        assert!(text.contains("<dc:title>A &amp; B</dc:title>"));
        assert!(text.contains("duration=\"0:01:01.500\""));
        assert!(text.contains("<sec:CaptionInfoEx sec:type=\"srt\">http://h/s/1/subs.srt</sec:CaptionInfoEx>"));
    }
}
