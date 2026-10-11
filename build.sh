#!/bin/bash
# Builds "Soft Subs.app" (helper app + Safari extension) into ./build. Pass --run to launch it afterwards.
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate --quiet
rm -rf build
xcodebuild -project SoftSubsAirPlay.xcodeproj -target SoftSubs -configuration Release \
    SYMROOT="$PWD/.build/xcode" CONFIGURATION_BUILD_DIR="$PWD/build" -quiet build
echo "Built build/Soft Subs.app"

if [[ "${1:-}" == "--run" ]]; then
    open "build/Soft Subs.app"
fi
