#!/bin/bash
# Xcode build phase: builds the Rust helper (v2/helper) for both Mac architectures, puts it in the app's
# Contents/MacOS with its login-item plist, and signs it so the app's own signature covers it.
set -euo pipefail

CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
[[ -x $CARGO ]] || CARGO=$(command -v cargo || true)
[[ -n $CARGO ]] || { echo "error: Soft Subs needs Rust to build its helper. Install it from https://rustup.rs" >&2; exit 1; }

HELPER="$SRCROOT/v2/helper"
TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
BINARIES=()
for target in "${TARGETS[@]}"; do
    (cd "$HELPER" && "$CARGO" build --release --quiet --target "$target")
    BINARIES+=("$HELPER/target/$target/release/softsubs-helper")
done

APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchAgents"
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/softsubs-helper"
cp "$SRCROOT/v2/mac/com.keivi.softsubs.helper.plist" "$APP/Contents/Library/LaunchAgents/"

# Nested code has to be signed before Xcode signs the app around it.
FLAGS=(--force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --identifier com.keivi.softsubs.helper)
if [[ ${ENABLE_HARDENED_RUNTIME:-NO} == YES ]]; then
    FLAGS+=(--options runtime --timestamp)
fi
codesign "${FLAGS[@]}" "$APP/Contents/MacOS/softsubs-helper"
