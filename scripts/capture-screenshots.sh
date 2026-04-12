#!/bin/bash
# Captures App Store screenshots of Spooktacular.
#
# Uses macOS built-in screencapture to capture the app window
# in each key state, then resizes for App Store requirements.
#
# Usage:
#   ./scripts/capture-screenshots.sh
#
# Output: fastlane/screenshots/en-US/
#
# App Store macOS screenshot sizes:
#   - 1280x800   (13" non-Retina)
#   - 1440x900   (13" non-Retina alt)
#   - 2560x1600  (13" Retina)
#   - 2880x1800  (15"/16" Retina)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_DIR/fastlane/screenshots/en-US"
APP="$PROJECT_DIR/Spooktacular.app"

# Ensure app is built
if [ ! -d "$APP" ]; then
    echo "Building app..."
    chmod +x "$PROJECT_DIR/build-app.sh"
    "$PROJECT_DIR/build-app.sh" release
fi

mkdir -p "$OUTPUT_DIR"

echo "Launching Spooktacular for screenshots..."
open "$APP"
sleep 3  # Wait for app to fully launch

# Get the window ID
WINDOW_ID=$(osascript -e 'tell application "Spooktacular" to id of window 1' 2>/dev/null || echo "")

capture() {
    local name="$1"
    local delay="${2:-1}"

    sleep "$delay"

    echo "  Capturing: $name"

    # Capture the focused window
    screencapture -l"$(osascript -e 'tell app "Spooktacular" to id of window 1')" \
        "$OUTPUT_DIR/${name}_raw.png" 2>/dev/null \
    || screencapture -w "$OUTPUT_DIR/${name}_raw.png" 2>/dev/null \
    || screencapture "$OUTPUT_DIR/${name}_raw.png"

    # Resize for App Store (2880x1800 Retina)
    sips -z 1800 2880 "$OUTPUT_DIR/${name}_raw.png" \
        --out "$OUTPUT_DIR/${name}.png" >/dev/null 2>&1 \
    || cp "$OUTPUT_DIR/${name}_raw.png" "$OUTPUT_DIR/${name}.png"

    rm -f "$OUTPUT_DIR/${name}_raw.png"
}

echo "Capturing screenshots..."

# 1. Empty state (no VMs)
capture "01_empty_state"

# 2. Open Create VM sheet
osascript -e 'tell app "System Events" to keystroke "n" using command down' 2>/dev/null || true
capture "02_create_vm_sheet" 2

# 3. Close sheet, show VM list (if VMs exist)
osascript -e 'tell app "System Events" to key code 53' 2>/dev/null || true  # Escape
capture "03_vm_list" 1

# 4. Menu bar dropdown
osascript -e 'tell app "System Events" to click menu bar item 1 of menu bar 2 of process "Spooktacular"' 2>/dev/null || true
capture "04_menu_bar" 2

echo ""
echo "✓ Screenshots saved to: $OUTPUT_DIR/"
echo ""
echo "Files:"
ls -1 "$OUTPUT_DIR"/*.png 2>/dev/null || echo "  (no screenshots captured — run manually if automated capture failed)"
echo ""
echo "Note: For best results, manually arrange the app window"
echo "before running this script. Set window to ~1440x900 for"
echo "optimal App Store screenshot proportions."
echo ""
echo "Tip: Use Cmd+Shift+4 then Space to manually capture"
echo "individual windows with macOS's built-in shadow effect."
