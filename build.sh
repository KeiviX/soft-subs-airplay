#!/bin/bash
# Builds "Soft Subs.app" (helper app + Safari extension) into ./build. Pass --run to launch it afterwards.
# XCODEBUILD_XCCONFIG can point at an .xcconfig of extra settings (used by scripts/release.sh).
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate --quiet
rm -rf build
xcodebuild -project SoftSubsAirPlay.xcodeproj -target SoftSubs -configuration Release \
    SYMROOT="$PWD/.build/xcode" CONFIGURATION_BUILD_DIR="$PWD/build" ${XCODEBUILD_XCCONFIG:+-xcconfig "$XCODEBUILD_XCCONFIG"} -quiet build
echo "Built build/Soft Subs.app"

if [[ "${1:-}" == "--run" ]]; then
    open "build/Soft Subs.app"
fi
