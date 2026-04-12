#!/bin/bash
# Creates AppIcon.icns from a source PNG or SVG.
# Usage: ./scripts/create-icns.sh [input.png]
#
# If no input is given, converts Resources/icon.svg using sips.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESOURCES_DIR="$PROJECT_DIR/Resources"
ICONSET_DIR="$RESOURCES_DIR/AppIcon.iconset"
OUTPUT="$RESOURCES_DIR/AppIcon.icns"

INPUT="${1:-}"

# If no input, try to render SVG to PNG via qlmanage (built-in)
if [ -z "$INPUT" ]; then
    SVG="$RESOURCES_DIR/icon.svg"
    if [ ! -f "$SVG" ]; then
        echo "Error: No input file and no Resources/icon.svg found."
        exit 1
    fi

    echo "Rendering SVG to PNG..."
    INPUT="$RESOURCES_DIR/icon_1024.png"

    # Use qlmanage to render SVG to PNG (built into macOS)
    qlmanage -t -s 1024 -o "$RESOURCES_DIR" "$SVG" 2>/dev/null
    RENDERED="$RESOURCES_DIR/icon.svg.png"
    if [ -f "$RENDERED" ]; then
        mv "$RENDERED" "$INPUT"
    else
        echo "Error: Failed to render SVG. Provide a 1024x1024 PNG instead."
        echo "Usage: $0 /path/to/icon.png"
        exit 1
    fi
fi

if [ ! -f "$INPUT" ]; then
    echo "Error: Input file not found: $INPUT"
    exit 1
fi

echo "Creating icon set from: $INPUT"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

# Generate all required sizes
sips -z   16   16 "$INPUT" --out "$ICONSET_DIR/icon_16x16.png"      >/dev/null
sips -z   32   32 "$INPUT" --out "$ICONSET_DIR/icon_16x16@2x.png"   >/dev/null
sips -z   32   32 "$INPUT" --out "$ICONSET_DIR/icon_32x32.png"      >/dev/null
sips -z   64   64 "$INPUT" --out "$ICONSET_DIR/icon_32x32@2x.png"   >/dev/null
sips -z  128  128 "$INPUT" --out "$ICONSET_DIR/icon_128x128.png"    >/dev/null
sips -z  256  256 "$INPUT" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z  256  256 "$INPUT" --out "$ICONSET_DIR/icon_256x256.png"    >/dev/null
sips -z  512  512 "$INPUT" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z  512  512 "$INPUT" --out "$ICONSET_DIR/icon_512x512.png"    >/dev/null
sips -z 1024 1024 "$INPUT" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

echo "Converting to .icns..."
iconutil -c icns -o "$OUTPUT" "$ICONSET_DIR"
rm -rf "$ICONSET_DIR"

echo "✓ Icon created: $OUTPUT"
