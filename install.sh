#!/bin/bash
# Installs Soft Subs AirPlay.
#
#   curl -fsSL https://raw.githubusercontent.com/KeiviX/soft-subs-airplay/main/install.sh | bash
#
# Options (after `bash -s --`):
#   --source      build from source instead of downloading the latest release (needs Xcode)
#   --no-ffmpeg   don't install ffmpeg
set -euo pipefail

REPO=KeiviX/soft-subs-airplay
APP_NAME="Soft Subs.app"
FROM_SOURCE=0
WITH_FFMPEG=1
for arg in "$@"; do
    case $arg in
        --source) FROM_SOURCE=1 ;;
        --no-ffmpeg) WITH_FFMPEG=0 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

[[ $(uname) == Darwin ]] || fail "Soft Subs runs on macOS only."
MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
(( MACOS_MAJOR >= 15 )) || fail "Soft Subs needs macOS 15 or later (this Mac has $(sw_vers -productVersion))."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [[ $FROM_SOURCE == 0 ]]; then
    step "Finding the latest release"
    ZIP_URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
        | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/' || true)
    if [[ -z $ZIP_URL ]]; then
        echo "No release found, building from source instead."
        FROM_SOURCE=1
    fi
fi

if [[ $FROM_SOURCE == 1 ]]; then
    step "Building from source"
    xcodebuild -version >/dev/null 2>&1 || fail "Building from source needs Xcode (install it from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app)."
    if ! command -v xcodegen >/dev/null; then
        command -v brew >/dev/null || fail "Building from source needs XcodeGen. Install Homebrew (https://brew.sh), then run this again."
        brew install xcodegen
    fi
    git clone --depth 1 "https://github.com/$REPO.git" "$WORK/src"
    "$WORK/src/build.sh"
    BUILT="$WORK/src/build/$APP_NAME"
else
    step "Downloading $(basename "$ZIP_URL")"
    curl -fL --progress-bar "$ZIP_URL" -o "$WORK/app.zip"
    ditto -x -k "$WORK/app.zip" "$WORK"
    BUILT="$WORK/$APP_NAME"
fi
[[ -d $BUILT ]] || fail "The build didn't produce $APP_NAME."

if [[ $WITH_FFMPEG == 1 ]] && ! command -v ffmpeg >/dev/null; then
    step "Installing ffmpeg (for MP4/DASH videos and exact subtitle timing)"
    if command -v brew >/dev/null; then
        brew install ffmpeg
    else
        echo "Homebrew isn't installed, so skipping ffmpeg. HLS videos still work; see the README."
    fi
fi

step "Installing to Applications"
DEST=/Applications
[[ -w $DEST ]] || DEST="$HOME/Applications"
mkdir -p "$DEST"
osascript -e 'quit app "Soft Subs"' >/dev/null 2>&1 || true
rm -rf "${DEST:?}/$APP_NAME"
ditto "$BUILT" "$DEST/$APP_NAME"
xattr -dr com.apple.quarantine "$DEST/$APP_NAME" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/$APP_NAME"
open "$DEST/$APP_NAME"

step "Done: $DEST/$APP_NAME"
cat <<'NEXT'
Last step, in Safari:
  1. Settings → Extensions → turn on "Soft Subs AirPlay" → Allow on every website.
  2. Not listed? Settings → Advanced → "Show features for web developers",
     then Develop → Allow Unsigned Extensions (Safari resets this when it quits).

The Soft Subs app shows a reminder with an "Open Safari Settings" button until the extension is on.
NEXT
