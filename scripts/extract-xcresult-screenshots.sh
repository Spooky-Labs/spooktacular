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
#
# Xcode 26 compatibility:
#   The legacy `xcresulttool get/export` API plus jq-driven
#   enumeration broke on Xcode 26 runtime (runs 24621185718,
#   24621388785 — `Error: cannot create DataID with hash null`
#   and `--legacy flag is required`). This script now uses
#   `xcresulttool export attachments`, Apple's documented
#   modern replacement. That command writes every attachment
#   to the output dir along with a `manifest.json` describing
#   them; we then filter to PNG-named ones and rename using
#   the manifest's `suggestedHumanReadableName`.

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

# Stage to a tempdir so the manifest.json and any non-PNG
# attachments don't pollute the final screenshots directory.
STAGING=$(mktemp -d -t xcresult-extract-XXXXXX)
trap 'rm -rf "$STAGING"' EXIT

# Dump every attachment from every test. The command creates
# files named by SHA inside $STAGING and writes
# $STAGING/manifest.json mapping each hash to a human-readable
# name (matches the `XCTAttachment.name` we set in
# ScreenshotTests.swift).
xcrun xcresulttool export attachments \
    --path "$XCRESULT" \
    --output-path "$STAGING"

MANIFEST="$STAGING/manifest.json"
if [ ! -f "$MANIFEST" ]; then
    echo "error: xcresulttool did not produce a manifest.json" >&2
    exit 4
fi

# Walk the manifest; for each attachment whose suggested name
# ends in .png/.jpg/.jpeg, copy it into $OUT under its
# sanitized human-readable name.
#
# manifest.json schema (v0.1.0):
#   [
#     {
#       "testIdentifier": "...",
#       "testName": "...",
#       "attachments": [
#         { "exportedFileName": "<hash>",
#           "suggestedHumanReadableName": "01_empty_state.png",
#           ... }
#       ]
#     },
#     ...
#   ]
jq -r '
    .[]?
    | .attachments[]?
    | [.exportedFileName, (.suggestedHumanReadableName // "screenshot.png")]
    | @tsv
' "$MANIFEST" | while IFS=$'\t' read -r SRC NAME; do
    [ -z "$SRC" ] && continue

    SAFE_NAME=$(printf '%s' "$NAME" | tr -cs 'A-Za-z0-9._-' '_')
    case "$SAFE_NAME" in
        *.png|*.PNG|*.jpg|*.JPG|*.jpeg|*.JPEG) ;;
        *) continue ;;  # Skip non-image attachments (logs, videos).
    esac

    if [ -f "$STAGING/$SRC" ]; then
        cp "$STAGING/$SRC" "$OUT/$SAFE_NAME"
    fi
done

# Report what we pulled out so the caller (CI job, developer) can
# eyeball the result without re-reading the script.
COUNT=$(find "$OUT" -maxdepth 1 -type f \( -name '*.png' -o -name '*.PNG' \) | wc -l | tr -d ' ')
echo "Extracted ${COUNT} screenshot(s) into ${OUT}"
