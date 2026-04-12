#!/bin/bash
# Post-processes screenshots for App Store submission.
#
# Takes raw screenshots from XCUITest or screencapture and
# produces properly sized versions for all required App Store
# display sizes.
#
# Usage:
#   ./scripts/process-screenshots.sh
#
# Input:  fastlane/screenshots/en-US/*.png (raw captures)
# Output: fastlane/screenshots/en-US/ (resized + organized)
#
# macOS App Store requires these sizes:
#   - 2880x1800 (Mac with 16-inch Retina display)
#   - 2560x1600 (Mac with 13-inch Retina display)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCREENSHOTS_DIR="$PROJECT_DIR/fastlane/screenshots/en-US"

if [ ! -d "$SCREENSHOTS_DIR" ]; then
    echo "Error: No screenshots directory at $SCREENSHOTS_DIR"
    echo "Run ./scripts/capture-screenshots.sh first."
    exit 1
fi

echo "Processing screenshots..."

for file in "$SCREENSHOTS_DIR"/*.png; do
    [ -f "$file" ] || continue

    base="$(basename "$file" .png)"
    echo "  Processing: $base"

    # Skip already-processed files
    if [[ "$base" == *"_retina16"* ]] || [[ "$base" == *"_retina13"* ]]; then
        continue
    fi

    # 16" Retina (2880x1800)
    sips -z 1800 2880 "$file" \
        --out "$SCREENSHOTS_DIR/${base}_retina16.png" >/dev/null 2>&1

    # 13" Retina (2560x1600)
    sips -z 1600 2560 "$file" \
        --out "$SCREENSHOTS_DIR/${base}_retina13.png" >/dev/null 2>&1
done

echo ""
echo "✓ Processed screenshots:"
ls -1 "$SCREENSHOTS_DIR"/*_retina*.png 2>/dev/null || echo "  (no files processed)"
echo ""
echo "These are ready for Fastlane deliver:"
echo "  fastlane release"
