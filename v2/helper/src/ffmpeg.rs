//! Finding and running ffmpeg/ffprobe, which do the media work Rust doesn't need to reimplement.

use std::path::PathBuf;
use std::process::Output;
use tokio::process::Command;

pub fn tool(name: &str) -> Option<PathBuf> {
    let file = if cfg!(windows) { format!("{name}.exe") } else { name.to_string() };
    let mut folders: Vec<PathBuf> = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].iter().map(PathBuf::from).collect();
    if let Some(path) = std::env::var_os("PATH") {
        folders.extend(std::env::split_paths(&path));
    }
    // A copy next to the helper wins, so an installer can ship its own.
    if let Some(own) = std::env::current_exe().ok().and_then(|exe| exe.parent().map(PathBuf::from)) {
        folders.insert(0, own);
    }
    folders.into_iter().map(|folder| folder.join(&file)).find(|candidate| candidate.is_file())
}

pub fn available() -> bool {
    tool("ffmpeg").is_some() && tool("ffprobe").is_some()
}

pub async fn run(program: &PathBuf, arguments: &[String]) -> std::io::Result<Output> {
    let mut command = Command::new(program);
    command.args(arguments).stdin(std::process::Stdio::null()).kill_on_drop(true);
    command.output().await
}
