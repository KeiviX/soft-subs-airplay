//! Requests to video hosts, sent with the browser's headers since the TV has none of them.

use bytes::{Bytes, BytesMut};
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use reqwest::Client;
use std::collections::HashMap;
use std::sync::OnceLock;
use std::time::{Duration, Instant};
use url::Url;

use crate::log;

pub type Headers = HashMap<String, String>;

pub struct Fetched {
    pub status: u16,
    /// The final URL after redirects.
    pub url: Url,
    pub headers: HeaderMap,
    pub body: Bytes,
}

impl Fetched {
    pub fn header(&self, name: &str) -> Option<String> {
        self.headers.get(name).and_then(|value| value.to_str().ok()).map(str::to_string)
    }

    pub fn content_type(&self) -> String {
        self.header("content-type").unwrap_or_default()
    }

    pub fn ok(&self) -> bool {
        (200..300).contains(&self.status)
    }
}

fn new_client() -> Client {
    Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .pool_idle_timeout(Duration::from_secs(90))
        .build()
        .expect("HTTP client")
}

fn shared() -> &'static Client {
    static CLIENT: OnceLock<Client> = OnceLock::new();
    CLIENT.get_or_init(new_client)
}

fn header_map(headers: &Headers) -> HeaderMap {
    let mut map = HeaderMap::new();
    for (name, value) in headers {
        if let (Ok(name), Ok(value)) = (HeaderName::from_bytes(name.as_bytes()), HeaderValue::from_str(value)) {
            map.insert(name, value);
        }
    }
    map
}

/// Sends one GET. `idle` is how long the response may go silent (no headers, or no new bytes) before the
/// request is abandoned, so a slow but steady download still completes.
async fn send(client: &Client, url: &Url, headers: &Headers, idle: Duration) -> Result<Fetched, String> {
    let request = client.get(url.clone()).headers(header_map(headers)).send();
    let mut response = tokio::time::timeout(idle.max(Duration::from_secs(10)), request)
        .await
        .map_err(|_| "no response".to_string())?
        .map_err(|error| describe(&error))?;
    let status = response.status().as_u16();
    let final_url = response.url().clone();
    let response_headers = response.headers().clone();
    let mut body = BytesMut::new();
    loop {
        match tokio::time::timeout(idle, response.chunk()).await {
            Err(_) => return Err(format!("stalled after {} bytes", body.len())),
            Ok(Err(error)) => return Err(describe(&error)),
            Ok(Ok(None)) => break,
            Ok(Ok(Some(chunk))) => body.extend_from_slice(&chunk),
        }
    }
    Ok(Fetched { status, url: final_url, headers: response_headers, body: body.freeze() })
}

fn describe(error: &reqwest::Error) -> String {
    let mut message = error.to_string();
    let mut source = std::error::Error::source(error);
    while let Some(inner) = source {
        message = format!("{message}: {inner}");
        source = inner.source();
    }
    message
}

/// Many hosts reject a full page URL as a hotlink but accept the bare origin, so retry 401/403 with that.
async fn send_with_referer_fallback(client: &Client, url: &Url, headers: &Headers, idle: Duration) -> Result<Fetched, String> {
    let fetched = send(client, url, headers, idle).await?;
    if ![401, 403].contains(&fetched.status) {
        return Ok(fetched);
    }
    let Some(referer) = headers.get("Referer").and_then(|value| Url::parse(value).ok()) else { return Ok(fetched) };
    let origin = format!("{}/", referer.origin().ascii_serialization());
    if referer.as_str() == origin {
        return Ok(fetched);
    }
    let mut retry = headers.clone();
    retry.insert("Referer".into(), origin);
    send(client, url, &retry, idle).await
}

pub async fn request(url: &Url, headers: &Headers) -> Result<Fetched, String> {
    send_with_referer_fallback(shared(), url, headers, Duration::from_secs(30)).await
}

/// Loads an http(s) URL, failing on non-2xx, or reads a file URL. Returns the final URL after redirects.
pub async fn load(url: &Url, headers: &Headers) -> Result<(Bytes, Url), String> {
    if url.scheme() == "file" {
        let path = url.to_file_path().map_err(|_| "bad file URL".to_string())?;
        return tokio::fs::read(&path).await.map(|data| (Bytes::from(data), url.clone())).map_err(|error| error.to_string());
    }
    let fetched = request(url, headers).await?;
    if !fetched.ok() {
        return Err(format!("{} refused the request (HTTP {}).", url.host_str().unwrap_or("The video host"), fetched.status));
    }
    Ok((fetched.body, fetched.url))
}

/// Fetches a media segment, retrying when the host stalls or fails.
///
/// Requests to one host share a connection, so when a CDN connection stalls, every request queued on it
/// stalls too. A request that goes quiet for a few seconds is abandoned and tried again on a new
/// connection instead of waiting out a long timeout while the TV runs dry.
pub async fn segment(url: &Url, headers: &Headers) -> Result<Fetched, String> {
    const ATTEMPTS: usize = 4;
    let name = url.path_segments().and_then(|mut parts| parts.next_back()).unwrap_or("").to_string();
    let mut last_error = String::new();
    for attempt in 0..ATTEMPTS {
        let fresh = (attempt > 0).then(new_client);
        let client = fresh.as_ref().unwrap_or_else(|| shared());
        let idle = Duration::from_secs(if attempt == 0 { 6 } else { 10 });
        let started = Instant::now();
        match send_with_referer_fallback(client, url, headers, idle).await {
            Ok(fetched) if fetched.status >= 500 && attempt < ATTEMPTS - 1 => {
                log::log(format!("retrying {name}: HTTP {}", fetched.status));
                last_error = format!("HTTP {}", fetched.status);
            }
            Ok(fetched) => return Ok(fetched),
            Err(error) => {
                log::log(format!("retrying {name} on a new connection after {:.1}s: {error}", started.elapsed().as_secs_f64()));
                last_error = error;
            }
        }
        tokio::time::sleep(Duration::from_millis(300 * (attempt as u64 + 1))).await;
    }
    Err(last_error)
}
