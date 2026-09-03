#!/usr/bin/env bash
# Type-check SheepitSDK against the real iOS SDK at the package's iOS 16 floor.
#
# `swift build` on macOS compiles the `#else` side of every
# `#if canImport(UIKit)` branch, so UIKit-only code (the background-flush
# lifecycle observer, UIDevice reads, FrameTracker) is never checked
# locally. This script closes that gap WITHOUT xcodebuild — which is
# banned in this repo because it exhausts RAM.
#
# Usage: packages/sdk-swift/scripts/typecheck-ios.sh
set -euo pipefail

cd "$(dirname "$0")/.."

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# SwiftPM builds the C target's module map for us; a raw swiftc invocation
# needs one written by hand.
cp Sources/SheepitCrashHandler/include/SheepitCrashHandler.h "$TMP_DIR/"
cat > "$TMP_DIR/module.modulemap" <<'MODULEMAP'
module SheepitCrashHandler {
    header "SheepitCrashHandler.h"
    export *
}
MODULEMAP

echo "→ swiftc -typecheck (arm64-apple-ios16.0)"
xcrun --sdk iphoneos swiftc -typecheck \
    -target arm64-apple-ios16.0 \
    -sdk "$SDK_PATH" \
    -Xcc -fmodule-map-file="$TMP_DIR/module.modulemap" \
    -I "$TMP_DIR" \
    $(find Sources/SheepitSDK -name '*.swift')

echo "✓ iOS type-check passed"
