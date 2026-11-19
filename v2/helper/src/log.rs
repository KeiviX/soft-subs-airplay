//! A plain-text log next to v1's, so failed casts can be diagnosed afterwards.

use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::SystemTime;

static WRITE: Mutex<()> = Mutex::new(());
static LAST_PROBLEM: Mutex<Option<String>> = Mutex::new(None);

pub fn folder() -> PathBuf {
    let home = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE")).unwrap_or_default();
    let home = PathBuf::from(home);
    if cfg!(target_os = "macos") {
        home.join("Library/Logs/SoftSubs")
    } else {
        home.join("AppData/Local/SoftSubs/logs")
    }
}

pub fn log(message: impl AsRef<str>) {
    let line = format!("{} [v2] {}\n", humantime::format_rfc3339_seconds(SystemTime::now()), message.as_ref());
    if std::env::var_os("SOFTSUBS_QUIET").is_none() {
        eprint!("{line}");
    }
    // Unit tests mustn't write into the person's real log.
    if cfg!(test) {
        return;
    }
    let _guard = WRITE.lock();
    let folder = folder();
    let _ = std::fs::create_dir_all(&folder);
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(folder.join("soft-subs.log")) {
        let _ = file.write_all(line.as_bytes());
    }
}

/// Remembers the most recent upstream failure so it can be shown next to a vaguer playback error.
pub fn problem(message: impl Into<String>) {
    let message = message.into();
    log(format!("PROBLEM {message}"));
    *LAST_PROBLEM.lock().unwrap() = Some(message);
}

pub fn take_problem() -> Option<String> {
    LAST_PROBLEM.lock().unwrap().take()
}

/// Keeps the last cast request (it includes the page's cookies) so a failed cast can be replayed.
pub fn save_last_cast(body: &[u8]) {
    let folder = folder();
    let _ = std::fs::create_dir_all(&folder);
    let _ = std::fs::write(folder.join("last-cast.json"), body);
}
