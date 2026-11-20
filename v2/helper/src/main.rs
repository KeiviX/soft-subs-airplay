//! Soft Subs v2 helper: a windowless server that rebuilds web video streams for TVs.
//!
//! The browser extension sends it a stream (with the page's headers and subtitles) and opens the helper's
//! player page. The page plays the rebuilt stream and the browser's own AirPlay hands it to the TV, which then
//! fetches everything from this server: playlists rewritten to come through here, segments downloaded ahead
//! with retries, disguised segments unwrapped, mono audio made stereo, and the subtitles as an HLS track.

mod audiofix;
mod cache;
mod dlna;
mod ffmpeg;
mod lan;
mod log;
mod playlist;
mod probe;
mod remux;
mod resp;
mod server;
mod sniff;
mod upstream;
mod webvtt;

use std::net::SocketAddr;

#[tokio::main]
async fn main() {
    let port: u16 = std::env::var("SOFTSUBS_PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(47800);
    let app = server::App::new(port);
    let router = axum::Router::new().fallback(server::route).with_state(app);

    let listener = match tokio::net::TcpListener::bind(SocketAddr::from(([0, 0, 0, 0], port))).await {
        Ok(listener) => listener,
        Err(error) => {
            // Usually another copy (or Soft Subs v1) is already serving; that one keeps working.
            log::log(format!("can't listen on port {port}: {error}"));
            std::process::exit(1);
        }
    };
    log::log(format!(
        "helper {} listening on port {port} (LAN address {}, ffmpeg {})",
        env!("CARGO_PKG_VERSION"),
        lan::current().unwrap_or_else(|| "none".into()),
        if ffmpeg::available() { "found" } else { "missing" }
    ));
    if let Err(error) = axum::serve(listener, router.into_make_service_with_connect_info::<SocketAddr>()).await {
        log::log(format!("server stopped: {error}"));
    }
}
