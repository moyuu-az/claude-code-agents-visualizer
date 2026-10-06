#!/usr/bin/env bash
# Builds "build/Claude Code Agents Visualizer.app" with SwiftPM alone (Xcode is not required).
#
#   scripts/build-app.sh                 # release build for this Mac's architecture, ad-hoc signed
#   UNIVERSAL=1 scripts/build-app.sh     # arm64 + x86_64
#   CODESIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Claude Code Agents Visualizer.app"
ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

swift build -c release --product AgentsVisualizer "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}"
BIN_DIR="$(swift build -c release --show-bin-path "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}")"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AgentsVisualizer" "$APP/Contents/MacOS/AgentsVisualizer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi

# "-" = ad-hoc signature: enough to run locally; distribution builds pass a Developer ID identity.
codesign --force --options runtime --sign "${CODESIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
