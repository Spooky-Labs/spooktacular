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
BUNDLE_DIR="$PROJECT_DIR/$APP_NAME.app"
CONTENTS="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
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

# Spooktacular Guest Tools — the in-guest companion app.
# Nested under Contents/Applications/ inside the host app so
# `AppBundleBootstrapTemplate.locateGuestToolsBundle()` can
# walk up from the running GUI executable to find it, tar it,
# and disk-inject it into every macOS VM on first-boot.
#
# The bundle is ITSELF a signed `.app` (sandboxed, distinct
# entitlements) — effectively a nested app, a pattern Apple
# supports for exactly this "ship a helper alongside the
# main app" use case.
GUEST_TOOLS_ID="com.spooktacular.GuestTools"
GUEST_TOOLS_TARGET="SpooktacularGuestTools"
GUEST_TOOLS_NAME="Spooktacular Guest Tools.app"
GUEST_TOOLS_DIR="$CONTENTS/Applications/$GUEST_TOOLS_NAME"
GUEST_TOOLS_CONTENTS="$GUEST_TOOLS_DIR/Contents"
GUEST_TOOLS_MACOS="$GUEST_TOOLS_CONTENTS/MacOS"
GUEST_TOOLS_ENTITLEMENTS="$PROJECT_DIR/SpooktacularGuestTools.entitlements"
GUEST_TOOLS_INFO_PLIST="$PROJECT_DIR/Resources/SpooktacularGuestTools-Info.plist"

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
mkdir -p "$MACOS_DIR" "$RESOURCES" "$XPC_HELPER_MACOS" "$GUEST_TOOLS_MACOS"

# Copy binaries. The legacy `spooktacular-agent` Mach-O is
# gone — its HTTP/vsock server moved into
# `SpooktacularGuestAgentCore` (library) and ships inside the
# Spooktacular Guest Tools nested `.app` (see step 3b below).
# No more base64 binary embedding; `DiskInjector.installGuestTools`
# ditto's the nested bundle directly onto the guest volume.
cp "$BINARY_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$BINARY_DIR/$CLI_TARGET" "$MACOS_DIR/$CLI_NAME"
chmod +x "$MACOS_DIR/$APP_NAME" "$MACOS_DIR/$CLI_NAME"

# Shared version/build stamps, injected into every embedded
# bundle's Info.plist below (VM Helper XPC service, Guest
# Tools) and into the provisioner pkg's version so
# `spooktacular doctor` and diagnostics across bundles all
# agree on one build identity.
BUNDLE_VERSION="${MARKETING_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo '1.0.0')}"
BUNDLE_BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo '1')}"

# 3a. Assemble VM Helper XPC service (Track J).
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
# Keep the embedded version numbers in sync with the app's
# so any future diagnostics (`spooktacular doctor`, Settings
# panel's helper probe) read consistent data across bundles.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $BUNDLE_VERSION" "$XPC_HELPER_CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUNDLE_BUILD" "$XPC_HELPER_CONTENTS/Info.plist"

# 3b. Assemble Spooktacular Guest Tools nested .app bundle.
#
# Layout:
#   Contents/Applications/Spooktacular Guest Tools.app/
#     Contents/
#       Info.plist                 — CFBundlePackageType=APPL, LSUIElement=true
#       MacOS/
#         SpooktacularGuestTools   — the executable (matches CFBundleExecutable)
#
# AppBundleBootstrapTemplate on the host GUI walks up from
# the running Spooktacular binary to find this nested `.app`,
# tars it + gzips it + base64-encodes it into a first-boot
# script, and DiskInjector drops that script on the guest's
# data volume so launchd installs the app to /Applications/
# on first boot — no DMG, no installer, no user intervention.
#
# Signed SEPARATELY (below) because it's a distinct sandbox
# boundary with its own entitlements (`app-sandbox`,
# `network.server`, tty file-exception for /dev/tty.com.redhat.spice.0).
echo "Assembling guest-tools nested app..."
cp "$BINARY_DIR/$GUEST_TOOLS_TARGET" "$GUEST_TOOLS_MACOS/$GUEST_TOOLS_TARGET"
chmod +x "$GUEST_TOOLS_MACOS/$GUEST_TOOLS_TARGET"
cp "$GUEST_TOOLS_INFO_PLIST" "$GUEST_TOOLS_CONTENTS/Info.plist"

# Provisioner pkg. Apple's macOS-14.4 sandbox rules forbid a
# sandboxed app from registering a LaunchDaemon via
# SMAppService.daemon unless the daemon is itself a sandboxed
# Mach-O — our runner is a bash script that needs to
# `mount_virtiofs` and exec arbitrary user scripts as root,
# which can't meet that requirement. The sanctioned escape
# hatch for "sandboxed app installs a privileged helper" is
# a signed `.pkg` that `Installer.app` (a system-privileged
# app) unpacks. Guest Tools ships this pkg in its Resources
# and opens it via `NSWorkspace.open(pkgURL)` when the user
# clicks Enable Provisioning.
#
# pkgbuild layout:
#   pkg-root/
#     Library/LaunchDaemons/com.spookylabs.spooktacular.provisioner.plist
#     usr/local/libexec/spook-provision-runner.sh
#   pkg-scripts/
#     postinstall  ← chown root:wheel + launchctl bootstrap
#
# `--install-location /` tells the installer to extract the
# payload relative to the system root, so
# `Library/LaunchDaemons/…` lands at `/Library/LaunchDaemons/…`.
echo "Building provisioner pkg..."
PKG_ROOT=$(mktemp -d)
PKG_SCRIPTS=$(mktemp -d)
mkdir -p "$PKG_ROOT/Library/LaunchDaemons"
mkdir -p "$PKG_ROOT/usr/local/libexec"
cp "$PROJECT_DIR/Resources/SpookProvisioner/com.spookylabs.spooktacular.provisioner.plist" \
   "$PKG_ROOT/Library/LaunchDaemons/com.spookylabs.spooktacular.provisioner.plist"
cp "$PROJECT_DIR/Resources/SpookProvisioner/spook-provision-runner.sh" \
   "$PKG_ROOT/usr/local/libexec/spook-provision-runner.sh"
chmod 644 "$PKG_ROOT/Library/LaunchDaemons/com.spookylabs.spooktacular.provisioner.plist"
chmod 755 "$PKG_ROOT/usr/local/libexec/spook-provision-runner.sh"
cp "$PROJECT_DIR/Resources/SpookProvisioner/postinstall" "$PKG_SCRIPTS/postinstall"
chmod 755 "$PKG_SCRIPTS/postinstall"

mkdir -p "$GUEST_TOOLS_CONTENTS/Resources"
PKG_OUTPUT="$GUEST_TOOLS_CONTENTS/Resources/Spooktacular Provisioner.pkg"

# Two-stage build: pkgbuild produces a *component* pkg with
# the raw payload + scripts; productbuild then wraps it as a
# *distribution* pkg with a Distribution.xml that
# Installer.app accepts in its GUI. A bare component pkg
# opens in Installer.app on macOS 14+ but the install button
# is non-functional — Installer requires a Distribution
# wrapper to actually run the install. That's why the
# previous build's payload never landed on disk despite the
# wizard appearing to complete.
COMPONENT_PKG=$(mktemp -t provisioner-component.XXXXXX).pkg
pkgbuild \
    --root "$PKG_ROOT" \
    --identifier com.spookylabs.spooktacular.provisioner \
    --version "${BUNDLE_VERSION:-1.0.0}" \
    --scripts "$PKG_SCRIPTS" \
    --install-location / \
    "$COMPONENT_PKG" \
    >/dev/null

# `--package <path>` embeds the component pkg inside the
# distribution pkg with the same identifier. `--root /` tells
# productbuild to synthesize a default Distribution.xml that
# installs the component to the system root — equivalent to
# the component pkg's `--install-location /`.
productbuild \
    --package "$COMPONENT_PKG" \
    "$PKG_OUTPUT" \
    >/dev/null

rm -f "$COMPONENT_PKG"

# Sign the pkg with Developer ID Installer if that cert is
# available. Without signing, Gatekeeper blocks the pkg when
# Guest Tools opens it via NSWorkspace on the end-user's Mac;
# with signing + notarization below, the Installer wizard
# launches with no warning. `bundle exec fastlane signing_dev_id`
# syncs the cert (Developer ID Application + Developer ID
# Installer in one match call).
if security find-identity -v -p basic | grep -q "Developer ID Installer"; then
    INSTALLER_IDENTITY=$(security find-identity -v -p basic \
        | grep "Developer ID Installer" | head -1 \
        | sed -E 's/.*"(.*)".*/\1/')
    productsign --sign "$INSTALLER_IDENTITY" "$PKG_OUTPUT" "${PKG_OUTPUT}.signed"
    mv "${PKG_OUTPUT}.signed" "$PKG_OUTPUT"
    echo "Signed provisioner pkg with: $INSTALLER_IDENTITY"

    # Notarize the pkg via notarytool when credentials are in
    # place. `xcrun notarytool submit --wait` blocks until
    # Apple's notary service returns, then `stapler staple`
    # attaches the ticket so Gatekeeper can validate offline.
    # On dev boxes without a notary keychain profile (the
    # common case), we skip with a hint — the pkg still
    # installs, just with a one-time "unidentified developer"
    # warning the user overrides via Privacy & Security.
    #
    # `NOTARY_PROFILE` names an `xcrun notarytool store-credentials`
    # entry (e.g. "spook-notary"). Set it via env or rely on CI
    # secrets; we probe `notarytool history` to confirm the
    # profile is actually resolvable before spending ~2 minutes
    # on a submit that's just going to 403.
    if [ -n "${NOTARY_PROFILE:-}" ] && xcrun notarytool history \
            --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
        echo "Notarizing provisioner pkg (this may take a minute)..."
        xcrun notarytool submit "$PKG_OUTPUT" \
            --keychain-profile "${NOTARY_PROFILE}" \
            --wait
        xcrun stapler staple "$PKG_OUTPUT"
        echo "Notarized + stapled provisioner pkg"
    else
        echo "Note: skipping pkg notarization — set NOTARY_PROFILE to a stored"
        echo "  notarytool keychain profile to enable. Unsigned/unnotarized"
        echo "  pkgs still install, but Gatekeeper shows a first-open warning."
    fi
else
    echo "Warning: no 'Developer ID Installer' cert in keychain — shipping unsigned provisioner pkg."
    echo "  Run 'bundle exec fastlane signing_dev_id' to sync the cert, then rebuild."
fi

rm -rf "$PKG_ROOT" "$PKG_SCRIPTS"
# Version-sync with the main app for consistent diagnostics
# — same rationale as the XPC helper block above.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $BUNDLE_VERSION" "$GUEST_TOOLS_CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUNDLE_BUILD" "$GUEST_TOOLS_CONTENTS/Info.plist"

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

# Resolve the provisioning profile.
#
# Restricted entitlements — application-identifier,
# team-identifier — require an embedded.provisionprofile in
# Contents/ whose allowlist covers each one. Without it, amfid
# rejects launch with "No matching profile found" (AMFIError -413)
# even when codesign itself validates.
#
# Discovery order:
#   1. `$PROVISIONING_PROFILE` — fastlane's `build` lane sets this
#      after `signing` (appstore) or `signing_dev` (development).
#   2. Newest profile in `~/Library/MobileDevice/Provisioning
#      Profiles/` whose application-identifier matches the app.
#   3. If neither resolves: build a **dev variant** with restricted
#      entitlements stripped. This mirrors Xcode's own behavior when
#      a developer opens a project with no profile: it signs a
#      local-run copy so the app launches on the developer's own
#      Mac. This is the standard local-dev signing shape Apple's
#      tooling produces.
if [ -z "${PROVISIONING_PROFILE:-}" ]; then
    PROVISIONING_PROFILE="$("$PROJECT_DIR/scripts/find-provisioning-profile.sh" \
        com.spooktacular.app 2>/dev/null || true)"
fi

DEV_VARIANT=0
if [ -n "${PROVISIONING_PROFILE:-}" ] && [ -f "${PROVISIONING_PROFILE}" ]; then
    echo "Embedding provisioning profile: $(basename "$PROVISIONING_PROFILE")"
    cp "$PROVISIONING_PROFILE" "$CONTENTS/embedded.provisionprofile"
else
    echo "No provisioning profile — building dev variant."
    DEV_VARIANT=1
    # Strip restricted entitlements from every signed component.
    DEV_ENTITLEMENTS="$(mktemp -t spook-ent).plist"
    cp "$ENTITLEMENTS" "$DEV_ENTITLEMENTS"
    for key in \
        com.apple.application-identifier \
        com.apple.developer.team-identifier; do
        /usr/libexec/PlistBuddy -c "Delete :$key" "$DEV_ENTITLEMENTS" 2>/dev/null || true
    done
    ENTITLEMENTS="$DEV_ENTITLEMENTS"
    DEV_CLI_ENTITLEMENTS="$(mktemp -t spook-cli-ent).plist"
    cp "$CLI_ENTITLEMENTS" "$DEV_CLI_ENTITLEMENTS"
    for key in com.apple.application-identifier com.apple.developer.team-identifier; do
        /usr/libexec/PlistBuddy -c "Delete :$key" "$DEV_CLI_ENTITLEMENTS" 2>/dev/null || true
    done
    CLI_ENTITLEMENTS="$DEV_CLI_ENTITLEMENTS"
    DEV_XPC_ENTITLEMENTS="$(mktemp -t spook-xpc-ent).plist"
    cp "$XPC_HELPER_ENTITLEMENTS" "$DEV_XPC_ENTITLEMENTS"
    for key in com.apple.application-identifier com.apple.developer.team-identifier; do
        /usr/libexec/PlistBuddy -c "Delete :$key" "$DEV_XPC_ENTITLEMENTS" 2>/dev/null || true
    done
    XPC_HELPER_ENTITLEMENTS="$DEV_XPC_ENTITLEMENTS"
    # Guest-tools nested .app keeps its full sandbox
    # entitlements in every variant. Per Apple's TN3125,
    # `com.apple.security.app-sandbox` + hardened-runtime
    # + file-access exceptions are all UNRESTRICTED
    # entitlements that don't require a provisioning
    # profile — amfid accepts them with any valid cert.
    # The guest-tools codesign block below uses an Apple
    # Distribution (or Developer ID) cert rather than the
    # device-locked Apple Development cert used for the
    # outer app in dev-variant builds, so the nested
    # bundle launches on fresh guest VMs.
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
#   1. VM Helper XPC executable + bundle (nested).
#   2. CLI binary (sibling of the app binary).
#   3. App binary.
#   4. App bundle root (covers everything above).
codesign --force --sign "$SIGN_IDENTITY" --options runtime $TIMESTAMP_FLAG --entitlements "$XPC_HELPER_ENTITLEMENTS" "$XPC_HELPER_MACOS/$XPC_HELPER_ID"
codesign --force --sign "$SIGN_IDENTITY" --options runtime $TIMESTAMP_FLAG --entitlements "$XPC_HELPER_ENTITLEMENTS" "$XPC_HELPER_DIR"
# Guest-tools nested .app — signed with an identity that
# runs on ANY Mac (unlike `Apple Development:` which is
# tied to per-device dev profiles).
#
# Apple's TN3125 (Inside Code Signing: Provisioning
# Profiles) documents that an app whose entitlements are
# all UNRESTRICTED — `com.apple.security.app-sandbox`,
# hardened-runtime config, file-access exceptions — needs
# no provisioning profile to launch. Every entitlement in
# `SpooktacularGuestTools.entitlements` is in that
# unrestricted set, so amfid will accept the nested bundle
# on a fresh macOS guest without a profile embedded.
#
# Identity selection, in priority order:
#   1. `$GUEST_TOOLS_SIGN_IDENTITY` env override — for
#      advanced operators who have a Developer ID App
#      cert and want to ship fully-notarizable guest
#      tools.
#   2. First `Apple Distribution:` cert in the login
#      keychain — ships with most match-managed teams,
#      works for any Mac without per-device registration.
#   3. `Developer ID Application:` as a fallback.
#   4. Ad-hoc `--sign -` as a last resort (loses sandbox
#      and notarization capability; emergency-only).
if [ -n "${GUEST_TOOLS_SIGN_IDENTITY:-}" ]; then
    GT_IDENTITY="$GUEST_TOOLS_SIGN_IDENTITY"
    GT_IDENTITY_LABEL="(explicit override)"
else
    # `security find-identity` output: `<n>) <SHA1-HASH> "<cert name>"`
    # Extract the HASH (column 2), not the name — cert-name
    # ambiguity (multiple identical-CN certs in the keychain,
    # common after renewal) makes codesign fail with:
    #   "ambiguous (matches ... and ... in ...keychain-db)"
    # A SHA-1 hash is always unique and unambiguous.
    GT_IDENTITY="$(security find-identity -v -p codesigning | \
        awk '/"Apple Distribution:/ { print $2; exit }')"
    GT_IDENTITY_LABEL="(Apple Distribution)"
    if [ -z "$GT_IDENTITY" ]; then
        GT_IDENTITY="$(security find-identity -v -p codesigning | \
            awk '/"Developer ID Application:/ { print $2; exit }')"
        GT_IDENTITY_LABEL="(Developer ID Application)"
    fi
fi
if [ -n "$GT_IDENTITY" ]; then
    # Strip the two restricted entitlement keys
    # (`com.apple.application-identifier` and
    # `com.apple.developer.team-identifier`) before signing.
    # Per Apple TN3125, restricted entitlements require a
    # matching provisioning profile at launch — and we
    # deliberately DON'T embed a profile in the nested
    # guest-tools bundle so it can run on any macOS guest.
    # Everything else in the entitlements file
    # (`app-sandbox`, `network.server`, file exception) is
    # UNRESTRICTED per the same technote, so the bundle
    # still sandboxes correctly on every target Mac.
    GT_EFFECTIVE_ENTITLEMENTS="$(mktemp -t spook-gt-eff).plist"
    cp "$GUEST_TOOLS_ENTITLEMENTS" "$GT_EFFECTIVE_ENTITLEMENTS"
    for key in com.apple.application-identifier com.apple.developer.team-identifier; do
        /usr/libexec/PlistBuddy -c "Delete :$key" "$GT_EFFECTIVE_ENTITLEMENTS" 2>/dev/null || true
    done
    echo "Signing guest-tools nested bundle: $GT_IDENTITY $GT_IDENTITY_LABEL"
    codesign --force --sign "$GT_IDENTITY" --options runtime $TIMESTAMP_FLAG --entitlements "$GT_EFFECTIVE_ENTITLEMENTS" "$GUEST_TOOLS_MACOS/$GUEST_TOOLS_TARGET"
    codesign --force --sign "$GT_IDENTITY" --options runtime $TIMESTAMP_FLAG --entitlements "$GT_EFFECTIVE_ENTITLEMENTS" "$GUEST_TOOLS_DIR"
else
    echo "⚠  No Apple Distribution / Developer ID identity — falling back to ad-hoc (guest-tools won't be notarizable)."
    codesign --force --sign - "$GUEST_TOOLS_MACOS/$GUEST_TOOLS_TARGET"
    codesign --force --sign - "$GUEST_TOOLS_DIR"
fi
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
