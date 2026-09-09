#!/usr/bin/env bash
# Type-check SheepitKit against the real iOS SDK at the package's iOS 16 floor.
#
# `swift build` on macOS compiles the `#else` side of every
# `#if canImport(UIKit)` branch, so UIKit-only code (the background-flush
# lifecycle observer, UIDevice reads, FrameTracker) is never checked
# locally. This script closes that gap WITHOUT xcodebuild — which is
# banned in this repo because it exhausts RAM.
#
# It also compiles the README's flagship usage sample. That sample ships to
# the public SPM mirror verbatim, and nothing else in the repo ever compiles
# it — which is how a `.environment(sheepit)` call that requires `Observable`
# (iOS 17, above this package's floor) sat in the published README through two
# releases. Extracting from the README rather than keeping a copy means there
# is one source of truth and no drift to detect.
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

# Pull the README block containing `@main` — the complete-app sample a reader
# copies first. `import SheepitKit` is stripped because everything is compiled
# as one module here; a missing block is a hard failure, not a skip, since it
# means the README changed shape and this guard silently stopped guarding.
python3 - "$TMP_DIR/ReadmeSample.swift" <<'PY_EXTRACT'
import re, sys

blocks = re.findall(r"```swift\n(.*?)```", open("README.md", encoding="utf-8").read(), re.S)
sample = [b for b in blocks if "@main" in b]
if len(sample) != 1:
    sys.exit(
        f"typecheck-ios: expected exactly one ```swift block containing @main in README.md, "
        f"found {len(sample)}. The usage sample is compiled by this script; if it moved or was "
        f"renamed, update the extraction rather than dropping the check."
    )
body = "\n".join(l for l in sample[0].splitlines() if l.strip() != "import SheepitKit")
open(sys.argv[1], "w", encoding="utf-8").write(body)
PY_EXTRACT

echo "→ swiftc -typecheck (arm64-apple-ios16.0), sources + README sample"
xcrun --sdk iphoneos swiftc -typecheck \
    -target arm64-apple-ios16.0 \
    -sdk "$SDK_PATH" \
    -Xcc -fmodule-map-file="$TMP_DIR/module.modulemap" \
    -I "$TMP_DIR" \
    $(find Sources/SheepitKit -name '*.swift') "$TMP_DIR/ReadmeSample.swift"

echo "✓ iOS type-check passed"
