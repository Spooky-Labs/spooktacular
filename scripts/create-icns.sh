#!/bin/bash
# Creates AppIcon.icns from a source PNG or SVG.
# Usage: ./scripts/create-icns.sh [input.png]
#
# If no input is given, renders Resources/icon.svg to PNG via
# `rsvg-convert` (librsvg) and then generates every required
# size with `sips`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESOURCES_DIR="$PROJECT_DIR/Resources"
ICONSET_DIR="$RESOURCES_DIR/AppIcon.iconset"
OUTPUT="$RESOURCES_DIR/AppIcon.icns"

INPUT="${1:-}"

# If no input is given, render the canonical SVG to a 1024x1024
# PNG via `rsvg-convert`. We previously used `qlmanage -t` but
# Quick Look's SVG thumbnailer produces an all-black image for
# anything with gradients — the rendered `.icns` looked like a
# solid black square in TestFlight (screenshot evidence in PR
# #30's description). `rsvg-convert` is librsvg's reference
# renderer and handles gradients, text, and nested groups
# correctly.
if [ -z "$INPUT" ]; then
    SVG="$RESOURCES_DIR/icon.svg"
    if [ ! -f "$SVG" ]; then
        echo "Error: No input file and no Resources/icon.svg found." >&2
        exit 1
    fi

    if ! command -v rsvg-convert >/dev/null 2>&1; then
        echo "Error: rsvg-convert not found. Install with:" >&2
        echo "  brew install librsvg" >&2
        echo "or pass an already-rendered PNG:" >&2
        echo "  $0 /path/to/icon.png" >&2
        exit 2
    fi

    echo "Rendering SVG to PNG via rsvg-convert..."
    INPUT="$RESOURCES_DIR/icon_1024.png"
    rsvg-convert -w 1024 -h 1024 "$SVG" -o "$INPUT"
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
