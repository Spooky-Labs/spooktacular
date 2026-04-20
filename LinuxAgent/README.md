# Spooktacular Linux Guest Agent

Minimal Swift-on-Linux port of `spooktacular-agent`. Runs inside a
Linux guest VM, listens on a VirtIO-socket port, and speaks the
same HTTP/1.1 wire protocol the macOS agent uses — so the host's
`GuestAgentClient` doesn't care which OS is answering.

## What it serves

```
GET /health                               → {"ok":true}
GET /api/v1/stats                         → one-shot GuestStatsResponse
GET /api/v1/events/stream?topics=stats,ports → NDJSON event stream
GET /api/v1/ports                         → [GuestPortInfo]
```

Everything else (exec, clipboard, apps, break-glass tickets) is
macOS-only and this Linux build genuinely cannot serve them.

## Build

Inside the Linux guest (e.g., Fedora):

```bash
# One-time: install Swift if missing
sudo dnf install -y swift-lang          # Fedora 41+
# (or download from https://swift.org/install/linux/)

git clone https://github.com/Spooky-Labs/spooktacular.git
cd spooktacular/LinuxAgent
swift build -c release
```

Produces `.build/release/spooktacular-agent`.

## Install

```bash
sudo install -m 0755 .build/release/spooktacular-agent \
    /usr/local/bin/spooktacular-agent
sudo /usr/local/bin/spooktacular-agent --install-unit
```

The installer writes `/etc/systemd/system/spooktacular-agent.service`,
runs `systemctl daemon-reload`, and `systemctl enable --now`. Check:

```bash
systemctl status spooktacular-agent
journalctl -u spooktacular-agent -f
```

## Verify from the host

From the macOS side, the chart in the GUI should start populating
within a second of the service coming up. For a quick sanity check
outside the GUI:

```bash
# Host-side:
spook remote curl <vm-name> /api/v1/stats | jq
```

## Why a separate SwiftPM package?

The main repo's `Package.swift` targets `.macOS("26.0")` and its
libraries import `Virtualization`, `AppKit`, `Security`, `CryptoKit`,
and `os` — none of which are available on Linux. Isolating the
Linux agent into its own subdirectory means:

- `swift build` in the repo root stays Apple-only.
- The Linux build has a clean dependency graph (Foundation + Glibc
  + one C shim for `<linux/vm_sockets.h>`).
- There's no `#if os(Linux)` rot threading through the main
  codebase.

Wire-protocol parity is maintained by hand: the JSON shapes emitted
here (`StatsFrame`, `PortEntry`, the `{topic,data}` envelope) match
the types the host decodes in `SpooktacularCore.GuestEvent` /
`GuestStatsResponse` / `GuestPortInfo`. Any change to one must be
reflected in the other — a small CI check that diffs the two
encoders would be useful once the Linux agent graduates past
metrics-only.
