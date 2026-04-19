#!/bin/bash
# Extracts XCTAttachment PNGs from an .xcresult bundle into a
# flat directory.
#
# The UI-test screenshot suite in
# `Tests/SpooktacularUITests/ScreenshotTests.swift` adds each
# captured image to the test run with `XCTAttachment`. Those
# attachments live inside the `.xcresult` bundle produced by
# `xcodebuild test -resultBundlePath` (and by fastlane `scan`
# with `result_bundle: true`).
#
# Usage:
#   scripts/extract-xcresult-screenshots.sh <xcresult-path> <output-dir>
#
# Example:
#   scripts/extract-xcresult-screenshots.sh \
#     fastlane/test_output/Spooktacular.xcresult \
#     fastlane/screenshots/en-US
#
# The output directory is created if missing. Existing files
# with the same attachment name are overwritten — re-runs are
# idempotent.

set -Eeuo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <xcresult-path> <output-dir>" >&2
    exit 2
fi

XCRESULT="$1"
OUT="$2"

if [ ! -d "$XCRESULT" ]; then
    echo "error: xcresult bundle not found: $XCRESULT" >&2
    exit 3
fi

mkdir -p "$OUT"

# The attachments live as opaque files under `Data/` inside the
# xcresult. Walk the manifest via `xcresulttool` to map each one
# to its human-readable `name`, then copy into place.
#
# `xcresulttool` is a code-signed Xcode binary; calling it is
# safer than traversing the bundle's internal layout by hand.
ROOT_JSON=$(xcrun xcresulttool get object --legacy --format json --path "$XCRESULT")

# Enumerate every test action's summary reference, then every
# attachment on every test. `jq` does the walking; we pipe each
# (ref_id, name) pair into a loop that materializes the file.
echo "$ROOT_JSON" | jq -r '
    .actions._values[]?
    .actionResult.testsRef._values[]?
    // .actions._values[]?.actionResult.testsRef
    | .id._value
' 2>/dev/null | while read -r TESTS_REF; do
    [ -z "$TESTS_REF" ] && continue

    TEST_PLAN=$(xcrun xcresulttool get object --legacy --format json \
        --path "$XCRESULT" --id "$TESTS_REF")

    echo "$TEST_PLAN" | jq -r '
        .. | objects
        | select(.attachments?)
        | .attachments._values[]
        | [.payloadRef.id._value, (.name._value // "screenshot")]
        | @tsv
    ' 2>/dev/null | while IFS=$'\t' read -r REF NAME; do
        [ -z "$REF" ] && continue
        # Sanitize the attachment name for the filesystem.
        SAFE_NAME=$(echo "$NAME" | tr -cs 'A-Za-z0-9._-' '_')
        # Only keep PNG/JPG attachments — skip logs, videos, etc.
        case "$SAFE_NAME" in
            *.png|*.PNG|*.jpg|*.JPG|*.jpeg|*.JPEG) ;;
            *) SAFE_NAME="${SAFE_NAME}.png" ;;
        esac
        xcrun xcresulttool export object \
            --legacy \
            --path "$XCRESULT" \
            --id "$REF" \
            --output-path "$OUT/$SAFE_NAME" \
            --type file 2>/dev/null || true
    done
done

# Report what we pulled out so the caller (CI job, developer) can
# eyeball the result without re-reading the script.
COUNT=$(find "$OUT" -maxdepth 1 -type f \( -name '*.png' -o -name '*.PNG' \) | wc -l | tr -d ' ')
echo "Extracted ${COUNT} screenshot(s) into ${OUT}"
