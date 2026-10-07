#!/usr/bin/env bash
# Builds the app and packages it for distribution:
#   build/ClaudeCodeAgentsVisualizer-<version>.dmg   drag-to-Applications disk image
#   build/ClaudeCodeAgentsVisualizer-<version>.zip   the .app, zipped with ditto (keeps signature and permissions)
#   build/SHA256SUMS.txt                             checksums of both
#
# The version comes from Resources/Info.plist (CFBundleShortVersionString), the single source of truth.
# Environment: UNIVERSAL=1 for arm64 + x86_64, CODESIGN_IDENTITY as in build-app.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Claude Code Agents Visualizer"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BASENAME="ClaudeCodeAgentsVisualizer-${VERSION}"
APP="build/${APP_NAME}.app"
DMG="build/${BASENAME}.dmg"
ZIP="build/${BASENAME}.zip"

scripts/build-app.sh

rm -f "$DMG" "$ZIP" build/SHA256SUMS.txt
ditto -c -k --keepParent "$APP" "$ZIP"

# Disk image with the app and a shortcut to /Applications, so installing is a single drag.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/${APP_NAME}.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "${APP_NAME} ${VERSION}" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"
hdiutil verify -quiet "$DMG"

(cd build && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > SHA256SUMS.txt)
echo "Packaged $DMG and $ZIP"
cat build/SHA256SUMS.txt
