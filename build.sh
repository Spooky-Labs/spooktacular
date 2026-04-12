#!/bin/bash
# Builds the spook CLI and codesigns it with the virtualization entitlement.
#
# Usage:
#   ./build.sh          Build debug
#   ./build.sh release  Build release
#
# The signed binary is placed at .build/spook (symlink to the
# actual binary in .build/debug/ or .build/release/).

set -euo pipefail

MODE="${1:-debug}"
ENTITLEMENTS="Spooktacular.entitlements"

if [ "$MODE" = "release" ]; then
    echo "Building release..."
    swift build -c release
    BINARY=".build/release/spook"
else
    echo "Building debug..."
    swift build
    BINARY=".build/debug/spook"
fi

echo "Signing with virtualization entitlement..."
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BINARY"

# Create a convenience symlink.
ln -sf "$BINARY" .build/spook

echo ""
echo "✓ Build complete: .build/spook"
echo ""
echo "Usage:"
echo "  .build/spook list"
echo "  .build/spook create my-vm --from-ipsw latest"
echo "  .build/spook start my-vm"
echo "  .build/spook clone my-vm runner-1"
echo "  .build/spook delete runner-1"
