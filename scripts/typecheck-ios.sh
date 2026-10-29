#!/usr/bin/env bash
# Type-check SheepitKit against the real iOS SDK at the package's iOS 16 floor.
#
# `swift build` on macOS compiles the `#else` side of every
# `#if canImport(UIKit)` branch, so UIKit-only code (the background-flush
# lifecycle observer, UIDevice reads, FrameTracker) is never checked
# locally. This script closes that gap WITHOUT xcodebuild — which is
# banned in this repo because it exhausts RAM.
#
# It also compiles the README's flagship usage sample, plus every README block
# preceded by a `<!-- typecheck: ... -->` comment (the in-app feedback samples).
# That sample ships to
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

readme = open("README.md", encoding="utf-8").read()
blocks = re.findall(r"```swift\n(.*?)```", readme, re.S)
sample = [b for b in blocks if "@main" in b]
if len(sample) != 1:
    sys.exit(
        f"typecheck-ios: expected exactly one ```swift block containing @main in README.md, "
        f"found {len(sample)}. The usage sample is compiled by this script; if it moved or was "
        f"renamed, update the extraction rather than dropping the check."
    )
# Opt-in blocks: a `<!-- typecheck: ... -->` line above the fence, blank lines allowed between
# (prettier inserts one). At least one must exist; zero means the markers were lost and the guard
# stopped guarding.
marked = re.findall(r"<!-- typecheck:[^>]*-->[ \t]*\n(?:[ \t]*\n)*```swift\n(.*?)```", readme, re.S)
if not marked:
    sys.exit("typecheck-ios: found no `<!-- typecheck: ... -->` swift block in README.md.")
# A marker whose block did not match (prose before the fence, a non-swift or indented fence) would
# otherwise be skipped silently.
markers = len(re.findall(r"<!-- typecheck:", readme))
if markers != len(marked):
    sys.exit(
        f"typecheck-ios: README.md has {markers} `<!-- typecheck: ... -->` markers but only "
        f"{len(marked)} are directly followed (blank lines aside) by a ```swift fence."
    )
strip = lambda b: "\n".join(l for l in b.splitlines() if l.strip() != "import SheepitKit")
open(sys.argv[1], "w", encoding="utf-8").write("\n\n".join(strip(b) for b in sample + marked))
PY_EXTRACT

# -warnings-as-errors matches check.sh's macOS half, for the half only this script
# compiles (`#if canImport(UIKit)`). `-typecheck` stops after type-checking, so it
# catches warnings emitted there, not later SIL-phase diagnostics. Toolchain-pinned:
# before bumping PINNED_XCODE_VERSION, run this script on the new Xcode and fix
# what it surfaces; a new SDK can turn a clean tree red here.
echo "→ swiftc -typecheck -warnings-as-errors (arm64-apple-ios16.0), sources + README sample"
xcrun --sdk iphoneos swiftc -typecheck \
    -warnings-as-errors \
    -target arm64-apple-ios16.0 \
    -sdk "$SDK_PATH" \
    -Xcc -fmodule-map-file="$TMP_DIR/module.modulemap" \
    -I "$TMP_DIR" \
    $(find Sources/SheepitKit -name '*.swift') "$TMP_DIR/ReadmeSample.swift"

echo "✓ iOS type-check passed"
