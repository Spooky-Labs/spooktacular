#!/bin/bash
# Creates AppIcon.icns from Resources/AppIcon.svg (the canonical
# pixel-art source used on the spooktacular.app website) or from
# an operator-supplied PNG.
#
# Usage:
#   ./scripts/create-icns.sh              # render Resources/AppIcon.svg
#   ./scripts/create-icns.sh icon.png     # use a pre-rendered PNG
#
# Why the double render step:
#
# `AppIcon.svg` defines its palette via CSS custom properties
# (`--bg1: #07050f;`, …) referenced by every rect via
# `fill="var(--bg1)"`. librsvg 2.62 (our renderer) does not
# resolve CSS custom properties — it falls back to the default
# fill, producing an all-black image (this bit us in an earlier
# TestFlight release). Safari and Chrome do resolve CSS vars,
# but aren't available headlessly on macos-26 runners.
#
# Fix: pre-substitute every `var(--name)` with its resolved
# `#rrggbb` value, then hand the resulting SVG to rsvg-convert.
# The 20-line Python below does exactly that and nothing else —
# no third-party deps beyond librsvg (already required).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESOURCES_DIR="$PROJECT_DIR/Resources"
ICONSET_DIR="$RESOURCES_DIR/AppIcon.iconset"
OUTPUT="$RESOURCES_DIR/AppIcon.icns"

INPUT="${1:-}"

# If no input is given, resolve CSS custom properties in
# `AppIcon.svg` and render to PNG via rsvg-convert.
if [ -z "$INPUT" ]; then
    SVG="$RESOURCES_DIR/AppIcon.svg"
    if [ ! -f "$SVG" ]; then
        echo "Error: No input file and no Resources/AppIcon.svg found." >&2
        exit 1
    fi

    if ! command -v rsvg-convert >/dev/null 2>&1; then
        echo "Error: rsvg-convert not found. Install with:" >&2
        echo "  brew install librsvg" >&2
        echo "or pass an already-rendered PNG:" >&2
        echo "  $0 /path/to/icon.png" >&2
        exit 2
    fi

    echo "Resolving CSS custom properties in AppIcon.svg..."
    RESOLVED_SVG="$(mktemp -t AppIcon-resolved-XXXXXX).svg"
    trap 'rm -f "$RESOLVED_SVG"' EXIT

    python3 - "$SVG" "$RESOLVED_SVG" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    svg = f.read()
# Collect `--name: value;` from the :root style block.
vars = dict(re.findall(r'--([\w-]+)\s*:\s*([^;]+);', svg))
# Substitute every `var(--name)` with its resolved value.
resolved = re.sub(
    r'var\(--([\w-]+)\)',
    lambda m: vars.get(m.group(1).strip(), m.group(0)),
    svg,
)
with open(dst, 'w') as f:
    f.write(resolved)
print(f"  {len(vars)} CSS vars resolved → {dst}")
PY

    echo "Rendering SVG → 1024x1024 PNG via rsvg-convert..."
    INPUT="$RESOURCES_DIR/icon_1024.png"
    rsvg-convert -w 1024 -h 1024 "$RESOLVED_SVG" -o "$INPUT"
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
