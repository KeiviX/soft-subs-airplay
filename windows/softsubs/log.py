"""Plain-text log and settings folder: %LOCALAPPDATA%\\SoftSubs on Windows, ~/Library/Logs/SoftSubs-Windows elsewhere."""

from __future__ import annotations

import os
import sys
import threading
from datetime import datetime, timezone
from pathlib import Path

if sys.platform == "win32":
    DATA_DIR = Path(os.environ.get("LOCALAPPDATA", Path.home())) / "SoftSubs"
else:
    DATA_DIR = Path(os.environ.get("SOFTSUBS_DATA_DIR", Path.home() / "Library/Logs/SoftSubs-Windows"))

LOG_FILE = DATA_DIR / "soft-subs.log"
_lock = threading.Lock()
_last_problem: str | None = None


def log(message: str) -> None:
    line = f"{datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')} {message}\n"
    with _lock:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a", encoding="utf-8") as handle:
            handle.write(line)


def problem(message: str) -> None:
    """Remembers the most recent upstream failure so it can be shown next to the receiver's vaguer error."""
    global _last_problem
    log(f"PROBLEM {message}")
    _last_problem = message


def take_problem() -> str | None:
    global _last_problem
    message, _last_problem = _last_problem, None
    return message


def save_last_cast(body: bytes) -> None:
    """Keeps the last cast request (it includes the page's cookies) for diagnosing failures."""
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    (DATA_DIR / "last-cast.json").write_bytes(body)
