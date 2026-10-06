#!/usr/bin/env bash
# Runs the test suite. Extra arguments go to `swift test` (e.g. `--filter SnapshotBuilderTests`).
set -euo pipefail
cd "$(dirname "$0")/.."

ARGS=()
# With only the Command Line Tools installed, SwiftPM intermittently fails to load the swift-testing macro
# plugin ("plugin for module 'TestingMacros' not found"). Pointing the compiler at it explicitly is reliable.
PLUGINS="$(xcode-select -p 2>/dev/null)/usr/lib/swift/host/plugins/testing"
if [[ -d "$PLUGINS" ]]; then ARGS=(-Xswiftc -plugin-path -Xswiftc "$PLUGINS"); fi

swift test "${ARGS[@]+"${ARGS[@]}"}" "$@"
