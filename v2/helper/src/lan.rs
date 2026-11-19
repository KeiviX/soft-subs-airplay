//! The computer's LAN address, which the TV uses to reach the stream server.

use std::net::IpAddr;

pub fn current() -> Option<String> {
    let interfaces = if_addrs::get_if_addrs().ok()?;
    let mut fallback = None;
    for interface in interfaces {
        let IpAddr::V4(ip) = interface.ip() else { continue };
        if ip.is_loopback() || ip.is_link_local() || ip.is_unspecified() {
            continue;
        }
        // On a Mac, en* is Wi-Fi or Ethernet; utun, bridge and awdl interfaces can't be reached by a TV.
        if cfg!(target_os = "macos") && !interface.name.starts_with("en") {
            continue;
        }
        if ip.is_private() {
            return Some(ip.to_string());
        }
        fallback.get_or_insert_with(|| ip.to_string());
    }
    fallback
}
