#!/usr/bin/env bash
# The Swift SDK gate — the ONE command that decides whether this package is OK.
#
# 🔴 Run THIS, never a bare `swift test`. Two lanes' worth of checks live here
# because both were previously inlined into workflow YAML, which meant nothing
# a human or an agent could run locally matched what CI actually enforced:
#
#   1. `-Xswiftc -warnings-as-errors`. A bare `swift test` passes on warnings
#      that are hard failures in CI. This bit live on PR #973: a test helper
#      returning `[String: Any]??` made `XCTAssertNotNil` emit "expression
#      implicitly coerced from '[String : Any]??' to 'Any?'" — a warning
#      locally, a build error on the runner. `swift test` reported 212/212
#      green while the lane never compiled the tests at all.
#
#   2. `typecheck-ios.sh`. `swift test` compiles the macOS host, so everything
#      behind `#if canImport(UIKit)` is NOT compiled by it. Until this script
#      existed, that typecheck ran only in `publish-sdk-swift.yml` — at tag
#      time, AFTER merge — so a PR could be fully green with a broken UIKit
#      branch and only break the release.
#
# Both workflows call this file, so the local command and the enforced command
# cannot drift apart again. Add a check here, not to the YAML.
#
# macOS-only: step 2 needs the real iPhoneOS SDK via `xcrun`. It fails loudly
# rather than skipping if that is unavailable — a skip would be a false green.
#
# Usage: packages/sdk-swift/scripts/check.sh
#
# For a fast inner loop while iterating, run `swift test --filter <Name>`
# directly — but this script is the gate, and it takes no arguments so that
# "check.sh passed" always means the same thing.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "▸ swift test (-warnings-as-errors)"
swift test -Xswiftc -warnings-as-errors

echo "▸ typecheck the #if canImport(UIKit) branches at the iOS 16 floor"
./scripts/typecheck-ios.sh

echo "✓ Swift SDK gate passed"
