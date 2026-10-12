#!/bin/bash
# Builds a release of Soft Subs and publishes it on GitHub.
#
#   scripts/release.sh 0.2.0            build, zip, tag v0.2.0 and create the GitHub release
#   scripts/release.sh 0.2.0 --dry-run  build and zip into dist/ only
#
# With a "Developer ID Application" certificate in your keychain the app is signed with it and the
# hardened runtime; set NOTARY_PROFILE to a `xcrun notarytool store-credentials` profile name to
# notarize and staple too. Without one it falls back to your Apple Development certificate, and
# friends have to approve the app in Privacy & Security and allow unsigned extensions in Safari.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: scripts/release.sh <version> [--dry-run]}
DRY_RUN=$([[ "${2:-}" == "--dry-run" ]] && echo 1 || echo 0)
BUILD_NUMBER=$(git rev-list --count HEAD)

if [[ $DRY_RUN == 0 && -n $(git status --porcelain) ]]; then
    echo "Commit or stash your changes first." >&2
    exit 1
fi

# The app, the extension and the extension manifest all carry the version. A dry run puts them back after.
mkdir -p .build
cp project.yml .build/project.yml.orig
cp Extension/Resources/manifest.json .build/manifest.json.orig
sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: $VERSION/" project.yml
sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"$VERSION\"/" Extension/Resources/manifest.json

CONFIG=.build/release.xcconfig
mkdir -p .build
echo "CURRENT_PROJECT_VERSION = $BUILD_NUMBER" > "$CONFIG"
DEVELOPER_ID=$(security find-identity -v -p codesigning | grep -m1 -o '"Developer ID Application[^"]*"' | tr -d '"' || true)
if [[ -n $DEVELOPER_ID ]]; then
    echo "Signing with $DEVELOPER_ID"
    cat >> "$CONFIG" <<CONFIG
CODE_SIGN_IDENTITY = Developer ID Application
DEVELOPMENT_TEAM = $(security find-certificate -c "$DEVELOPER_ID" -p | openssl x509 -noout -subject | sed -n 's/.*OU=\([A-Z0-9]*\).*/\1/p')
ENABLE_HARDENED_RUNTIME = YES
OTHER_CODE_SIGN_FLAGS = --timestamp
CONFIG
else
    echo "No Developer ID certificate found; signing with Apple Development (friends will need the manual steps in the README)."
fi
XCODEBUILD_XCCONFIG=$CONFIG ./build.sh

APP="build/Soft Subs.app"
ZIP="dist/SoftSubs-$VERSION.zip"
mkdir -p dist
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ -n $DEVELOPER_ID && -n ${NOTARY_PROFILE:-} ]]; then
    echo "Notarizing…"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
fi
echo "Packaged $ZIP ($(du -h "$ZIP" | cut -f1))"

if [[ $DRY_RUN == 1 ]]; then
    cp .build/project.yml.orig project.yml
    cp .build/manifest.json.orig Extension/Resources/manifest.json
    exit 0
fi

git diff --quiet || git commit -qam "Release $VERSION"
git tag "v$VERSION"
git push -q origin HEAD "v$VERSION"
NOTES=$(mktemp)
cat > "$NOTES" <<NOTES
**Mac (Safari):** download **SoftSubs-$VERSION.zip**, unzip it, and move **Soft Subs** to Applications. Or install from Terminal:
\`curl -fsSL https://raw.githubusercontent.com/KeiviX/soft-subs-airplay/main/install.sh | bash\`

**Windows (Chrome):** download **SoftSubs-Setup-$VERSION.exe** and run it, then load the extension in Chrome (Developer mode → Load unpacked → \`C:\\Program Files\\Soft Subs\\chrome-extension\`). The Windows files appear a few minutes after this release is published, once they are built.

See the [README](https://github.com/KeiviX/soft-subs-airplay#readme) for setup steps.
NOTES
gh release create "v$VERSION" "$ZIP" --title "Soft Subs $VERSION" --notes-file "$NOTES"
rm -f "$NOTES"
echo "Published v$VERSION. The Windows workflow will attach the installer: gh run list --workflow windows.yml"
