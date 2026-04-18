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
CLI_ENTITLEMENTS="$PROJECT_DIR/SpookCLI.entitlements"

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

# Copy Info.plist and inject version from git
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"
VERSION="${MARKETING_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo '1.0.0')}"
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo '1')}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$CONTENTS/Info.plist"

# Copy icon
if [ -f "$ICNS" ]; then
    cp "$ICNS" "$RESOURCES/AppIcon.icns"
fi

# Embed provisioning profile if PROVISIONING_PROFILE path is set
# (Fastlane sets this after match runs)
if [ -n "${PROVISIONING_PROFILE:-}" ] && [ -f "$PROVISIONING_PROFILE" ]; then
    echo "Embedding provisioning profile: $(basename "$PROVISIONING_PROFILE")"
    cp "$PROVISIONING_PROFILE" "$CONTENTS/embedded.provisionprofile"
fi

# 4. Code sign
# Use the signing identity from CODESIGN_IDENTITY env var if set
# (match sets this via MATCH_CODESIGN_IDENTITY), otherwise ad-hoc.
#
# Entitlements are passed to `codesign --entitlements` below and
# embedded into the signature. Do not copy the .entitlements file
# into Contents/ — a loose .plist there is treated by codesign as
# an unsigned subcomponent and triggers
#   "code object is not signed at all
#    In subcomponent: .../Contents/Entitlements.plist"
# when the bundle root is signed afterwards.
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
echo "Code signing with identity: $SIGN_IDENTITY"
# Sign inner binaries first, then the main executable, then the bundle.
# Never use --deep — it masks signing order bugs.
#
# --timestamp requests a secure timestamp from Apple's RFC 3161 TSA
# (timestamp.apple.com). Notarization rejects signatures without one,
# and a trusted timestamp keeps the signature verifiable even after
# the signing certificate expires. Ad-hoc builds (identity "-") skip
# the timestamp because the TSA will not stamp unsigned objects.
TIMESTAMP_FLAG=""
if [ "$SIGN_IDENTITY" != "-" ]; then
    TIMESTAMP_FLAG="--timestamp"
fi
codesign --force --sign "$SIGN_IDENTITY" --options runtime $TIMESTAMP_FLAG --entitlements "$CLI_ENTITLEMENTS" "$MACOS_DIR/$CLI_NAME"
codesign --force --sign "$SIGN_IDENTITY" --options runtime $TIMESTAMP_FLAG --entitlements "$ENTITLEMENTS" "$MACOS_DIR/$APP_NAME"
codesign --force --sign "$SIGN_IDENTITY" --options runtime $TIMESTAMP_FLAG --entitlements "$ENTITLEMENTS" "$BUNDLE_DIR"

echo ""
echo "✓ App bundle created: $BUNDLE_DIR"
echo ""
echo "Launch:"
echo "  open $BUNDLE_DIR"
echo ""
echo "CLI (from inside the bundle):"
echo "  $MACOS_DIR/$CLI_NAME list"
