#!/bin/bash
# Builds "Soft Subs.app" (helper app + Safari extension) into ./build. Pass --run to launch it afterwards.
# XCODEBUILD_XCCONFIG can point at an .xcconfig of extra settings (used by scripts/release.sh).
set -euo pipefail
cd "$(dirname "$0")"

# Sign with your Apple Development certificate if you have one (a stable signature keeps Safari's
# extension permissions across rebuilds); otherwise sign ad-hoc, which needs "Allow Unsigned Extensions".
mkdir -p .build
CONFIG="$PWD/.build/build.xcconfig"
: > "$CONFIG"
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Apple Development[^"]*"' | tr -d '"' || true)
if [[ -n $IDENTITY ]]; then
    TEAM=$(security find-certificate -c "$IDENTITY" -p | openssl x509 -noout -subject | sed -n 's/.*OU=\([A-Z0-9]*\).*/\1/p')
    printf 'CODE_SIGN_IDENTITY = Apple Development\nDEVELOPMENT_TEAM = %s\n' "$TEAM" >> "$CONFIG"
fi
if [[ -n ${XCODEBUILD_XCCONFIG:-} ]]; then
    echo "#include \"$(cd "$(dirname "$XCODEBUILD_XCCONFIG")" && pwd)/$(basename "$XCODEBUILD_XCCONFIG")\"" >> "$CONFIG"
fi

xcodegen generate --quiet
rm -rf build
xcodebuild -project SoftSubsAirPlay.xcodeproj -target SoftSubs -configuration Release \
    SYMROOT="$PWD/.build/xcode" CONFIGURATION_BUILD_DIR="$PWD/build" -xcconfig "$CONFIG" -quiet build
echo "Built build/Soft Subs.app"

if [[ "${1:-}" == "--run" ]]; then
    open "build/Soft Subs.app"
fi
