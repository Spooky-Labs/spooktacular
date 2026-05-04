#!/bin/bash
# Builds the Linux agent and installs it as a systemd service.
# Run this *inside* the Linux guest VM.
#
# Usage (inside the guest):
#   cd /path/to/spooktacular/LinuxAgent
#   sudo ./install-in-guest.sh

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "✗ Must be run as root (sudo). systemd unit install needs write access to /etc/systemd/system/." >&2
    exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
    echo "✗ swift not found on PATH." >&2
    echo "  Install Swift first:" >&2
    echo "    Fedora 41+: sudo dnf install -y swift-lang" >&2
    echo "    Others:    https://swift.org/install/linux/" >&2
    exit 1
fi

echo "Building release binary…"
swift build -c release

BINARY=".build/release/spooktacular-agent"
DEST="/usr/local/bin/spooktacular-agent"

echo "Installing binary to $DEST"
install -m 0755 "$BINARY" "$DEST"

echo "Registering systemd unit + starting…"
"$DEST" --install-unit

echo ""
echo "✓ Done. The agent is now listening on vsock:9470."
echo "  systemctl status  spooktacular-agent"
echo "  journalctl -u     spooktacular-agent -f"
