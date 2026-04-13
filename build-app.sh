#!/bin/bash
# Builds Spooktacular as a proper macOS .app bundle.
#
# Usage:
#   ./build-app.sh          Build debug .app
#   ./build-app.sh release  Build release .app
#
# Output: Spooktacular.app in the project root.

set -euo pipefail

MODE="${1:-debug}"
CONFIG_FLAG=""
if [ "$MODE" = "release" ]; then
    CONFIG_FLAG="-c release"
    echo "Building release..."
else
    echo "Building debug..."
fi

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Spooktacular"
CLI_NAME="spook"
BUNDLE_DIR="$PROJECT_DIR/$APP_NAME.app"
CONTENTS="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ENTITLEMENTS="$PROJECT_DIR/Spooktacular.entitlements"

# 1. Build all targets together
echo "Compiling..."
swift build $CONFIG_FLAG

BINARY_DIR="$(swift build $CONFIG_FLAG --show-bin-path)"

# 2. Generate icon if missing
ICNS="$PROJECT_DIR/Resources/AppIcon.icns"
if [ ! -f "$ICNS" ]; then
    echo "Generating app icon..."
    chmod +x "$PROJECT_DIR/scripts/create-icns.sh"
    "$PROJECT_DIR/scripts/create-icns.sh" || echo "Warning: Icon generation failed. Continuing without icon."
fi

# 3. Assemble .app bundle
echo "Assembling app bundle..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES"

# Copy binaries
cp "$BINARY_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$BINARY_DIR/$CLI_NAME" "$MACOS_DIR/$CLI_NAME"
chmod +x "$MACOS_DIR/$APP_NAME" "$MACOS_DIR/$CLI_NAME"

# Copy Info.plist
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"

# Copy icon
if [ -f "$ICNS" ]; then
    cp "$ICNS" "$RESOURCES/AppIcon.icns"
fi

# Copy entitlements
cp "$ENTITLEMENTS" "$CONTENTS/Entitlements.plist"

# 4. Code sign
echo "Code signing..."
codesign --force --sign - \
    --entitlements "$ENTITLEMENTS" \
    --deep \
    "$BUNDLE_DIR"

echo ""
echo "✓ App bundle created: $BUNDLE_DIR"
echo ""
echo "Launch:"
echo "  open $BUNDLE_DIR"
echo ""
echo "CLI (from inside the bundle):"
echo "  $MACOS_DIR/$CLI_NAME list"
