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
# CLI target name in Package.swift. The shipped binary in the
# .app is still called `spook` for user-facing ergonomics —
# renaming on copy below.
CLI_TARGET="spooktacular-cli"
CLI_NAME="spook"
# System-extension identity must match:
#   - CFBundleIdentifier in Resources/SpooktacularNetworkFilter-Info.plist
#   - NEFilterConfigurator.extensionBundleIdentifier
#   - com.apple.application-identifier in SpooktacularNetworkFilter.entitlements
SYSEX_ID="com.spooktacular.app.NetworkFilter"
SYSEX_TARGET="SpooktacularNetworkFilter"
BUNDLE_DIR="$PROJECT_DIR/$APP_NAME.app"
CONTENTS="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
SYSEX_DIR="$CONTENTS/Library/SystemExtensions/$SYSEX_ID.systemextension"
SYSEX_CONTENTS="$SYSEX_DIR/Contents"
SYSEX_MACOS="$SYSEX_CONTENTS/MacOS"
ENTITLEMENTS="$PROJECT_DIR/Spooktacular.entitlements"
# `spook` is a DUAL-USE CLI: the GUI app invokes it via
# `Process`, AND users run it directly from Terminal. Apple's
# canonical "embedded helper tool" pattern
# (`com.apple.security.inherit` + app-sandbox) only covers
# the first use case — when launched from bash, there's no
# parent sandbox to inherit from, and taskgated SIGTRAPs the
# process trying to enter a non-existent container.
#
# Reference-architecture choice: the CLI carries its own
# standalone entitlements (Virtualization, network, files)
# without `app-sandbox`. That's how Homebrew-distributed
# Mac CLIs work (Developer-ID-signed, no sandbox).
# Trade-off: when this CLI ships to the Mac App Store, it
# must be refactored into a pure `inherit` embedded-helper
# — App Store distribution requires sandbox on every
# bundled binary. Today's reference target is Developer-ID
# direct distribution (TestFlight + Homebrew tap), so the
# standalone-CLI shape is the right choice.
CLI_ENTITLEMENTS="$PROJECT_DIR/SpooktacularCLI.entitlements"
SYSEX_ENTITLEMENTS="$PROJECT_DIR/SpooktacularNetworkFilter.entitlements"
SYSEX_INFO_PLIST="$PROJECT_DIR/Resources/SpooktacularNetworkFilter-Info.plist"

# VM Helper XPC service (Track J). Bundled under
# Contents/XPCServices/; launchd spawns one process per
# parent app instance on first connection.
XPC_HELPER_ID="com.spooktacular.app.VMHelper"
XPC_HELPER_TARGET="SpooktacularVMHelper"
XPC_HELPER_DIR="$CONTENTS/XPCServices/$XPC_HELPER_ID.xpc"
XPC_HELPER_CONTENTS="$XPC_HELPER_DIR/Contents"
XPC_HELPER_MACOS="$XPC_HELPER_CONTENTS/MacOS"
XPC_HELPER_ENTITLEMENTS="$PROJECT_DIR/SpooktacularVMHelper.entitlements"
XPC_HELPER_INFO_PLIST="$PROJECT_DIR/Resources/SpooktacularVMHelper-Info.plist"

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
mkdir -p "$MACOS_DIR" "$RESOURCES" "$SYSEX_MACOS" "$XPC_HELPER_MACOS"

# Copy binaries
cp "$BINARY_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$BINARY_DIR/$CLI_TARGET" "$MACOS_DIR/$CLI_NAME"
chmod +x "$MACOS_DIR/$APP_NAME" "$MACOS_DIR/$CLI_NAME"

# 3a. Assemble system-extension bundle (Track F'').
#
# Apple's system-extension loader expects:
#   Contents/Library/SystemExtensions/<bundle-id>.systemextension/
#     Contents/
#       Info.plist
#       MacOS/
#         <CFBundleExecutable>   ← we name it <bundle-id> to match Info.plist
#
# The executable's CFBundleExecutable must equal the file
# name on disk; we rename on copy to keep both sides in sync
# with the Info.plist (which sets CFBundleExecutable to the
# bundle identifier string).
echo "Assembling system extension..."
cp "$BINARY_DIR/$SYSEX_TARGET" "$SYSEX_MACOS/$SYSEX_ID"
chmod +x "$SYSEX_MACOS/$SYSEX_ID"
cp "$SYSEX_INFO_PLIST" "$SYSEX_CONTENTS/Info.plist"
# Inject version/build into the extension Info.plist so
# OSSystemExtensionManager's version-comparison logic sees
# the same numbers the main app reports — the replace-vs-skip
# decision in `actionForReplacingExtension` reads these.
SYSEX_VERSION="${MARKETING_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo '1.0.0')}"
SYSEX_BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo '1')}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SYSEX_VERSION" "$SYSEX_CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $SYSEX_BUILD" "$SYSEX_CONTENTS/Info.plist"

# 3b. Assemble VM Helper XPC service (Track J).
#
# Bundle layout Apple expects:
#   Contents/XPCServices/<bundle-id>.xpc/
#     Contents/
#       Info.plist                 — CFBundlePackageType=XPC!, XPCService dict
#       MacOS/
#         <CFBundleExecutable>     — named after the bundle id for clarity
#
# launchd discovers the service by scanning XPCServices/
# when the main app opens NSXPCConnection(serviceName:)
# against the bundle id.
echo "Assembling VM helper XPC service..."
cp "$BINARY_DIR/$XPC_HELPER_TARGET" "$XPC_HELPER_MACOS/$XPC_HELPER_ID"
chmod +x "$XPC_HELPER_MACOS/$XPC_HELPER_ID"
cp "$XPC_HELPER_INFO_PLIST" "$XPC_HELPER_CONTENTS/Info.plist"
# Same reasoning as the sysex block: keep the embedded
# version numbers in sync with the app's so any future
# diagnostics (`spooktacular doctor`, Settings panel's
# helper probe) read consistent data across the two bundles.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SYSEX_VERSION" "$XPC_HELPER_CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $SYSEX_BUILD" "$XPC_HELPER_CONTENTS/Info.plist"

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
#
# Reference architecture: require a real Apple-issued signing
# identity (Apple Development for local dev, Apple Distribution /
# Developer ID Application for release). Ad-hoc signing fails
# at launch because `taskgated` refuses `app-sandbox` without
# a provisioning profile; there's no product path that works
# without real signing. So: no "ad-hoc fallback" — the script
# either signs with a real cert or exits with instructions.
#
# Discovery order:
#   1. `$CODESIGN_IDENTITY` — fastlane's `build` lane sets
#      this after `match` imports the cert into the keychain.
#   2. First `Apple Development:` cert in the login keychain
#      — the canonical local-dev flow. Install one with:
#        bundle exec fastlane match development
#
# Entitlements are passed to `codesign --entitlements` below
# and embedded into the signature. Do not copy the
# .entitlements file into Contents/ — a loose .plist there is
# treated by codesign as an unsigned subcomponent and triggers
#   "code object is not signed at all
#    In subcomponent: .../Contents/Entitlements.plist"
# when the bundle root is signed afterwards.
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning | \
        awk -F '"' '/"Apple Development:/ { print $2; exit }')
fi
if [ -z "$SIGN_IDENTITY" ]; then
    echo "✗ No code-signing identity found." >&2
    echo "  Install one via fastlane match (preferred):" >&2
    echo "    bundle exec fastlane signing" >&2
    echo "  Or pass the identity explicitly:" >&2
    echo "    CODESIGN_IDENTITY='Apple Development: Your Name (XXXX)' ./build-app.sh" >&2
    exit 1
fi
echo "Code signing with identity: $SIGN_IDENTITY"

# Sign inner binaries first, then the main executable, then the bundle.
# Never use --deep — it masks signing order bugs.
#
# --timestamp requests a secure timestamp from Apple's RFC 3161 TSA
# (timestamp.apple.com). Notarization rejects signatures without one,
# and a trusted timestamp keeps the signature verifiable even after
# the signing certificate expires.
TIMESTAMP_FLAG="--timestamp"
# Sign innermost-first so the outer signature can cover the
# now-signed inner subcomponents. Order:
#   1. System-extension executable + bundle (deepest nested).
#   2. VM Helper XPC executable + bundle (also nested).
#   3. CLI binary (sibling of the app binary).
#   4. App binary.
#   5. App bundle root (covers everything above).
codesign --force --sign "$SIGN_IDENTITY" --options runtime $TIMESTAMP_FLAG --entitlements "$SYSEX_ENTITLEMENTS" "$SYSEX_MACOS/$SYSEX_ID"
codesign --force --sign "$SIGN_IDENTITY" --options runtime $TIMESTAMP_FLAG --entitlements "$SYSEX_ENTITLEMENTS" "$SYSEX_DIR"
codesign --force --sign "$SIGN_IDENTITY" --options runtime $TIMESTAMP_FLAG --entitlements "$XPC_HELPER_ENTITLEMENTS" "$XPC_HELPER_MACOS/$XPC_HELPER_ID"
codesign --force --sign "$SIGN_IDENTITY" --options runtime $TIMESTAMP_FLAG --entitlements "$XPC_HELPER_ENTITLEMENTS" "$XPC_HELPER_DIR"
# CLI gets its own entitlements (`com.apple.security.inherit`
# in the canonical signed path) and a distinct code-signing
# identifier so Apple's embedded-tool pattern resolves
# cleanly at runtime. `-i com.spooktacular.app.cli` matches
# the convention shown in "Embedding a command-line tool
# in a sandboxed app" where the tool's identifier is a
# dotted-suffix of the parent app's bundle ID.
codesign --force --sign "$SIGN_IDENTITY" --options runtime $TIMESTAMP_FLAG \
    -i "com.spooktacular.app.cli" \
    --entitlements "$CLI_ENTITLEMENTS" "$MACOS_DIR/$CLI_NAME"
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
