# Spooktacular Linux Guest Agent

Minimal Swift-on-Linux port of `spooktacular-agent`. Runs inside
a Linux guest VM and pushes metrics to the host using Apple's
documented `VZVirtioSocketListener` pattern — the guest-to-host
direction of `Virtualization.framework`.

## Wire architecture

The host registers a `VZVirtioSocketListener` on port **9469**
via `VZVirtioSocketDevice.setSocketListener(_:forPort:)`. This
agent dials `VMADDR_CID_HOST:9469` at boot, keeps the connection
open, and pushes length-prefixed `GuestEvent` JSON frames:

```
┌──────────────────────┬──────────────────────────────┐
│  4-byte big-endian   │  N bytes of JSONEncoder      │
│  unsigned length N   │  output (a `GuestEvent` body)│
└──────────────────────┴──────────────────────────────┘
```

The framing lives in `SpooktacularCore.AgentFrameCodec` on the
host; the Linux agent re-implements the same shape verbatim so
the host's `AsyncThrowingStream<GuestEvent, Error>` decodes
identically regardless of which OS answered.

Per Apple's docs:

> *"An object that listens for port-based connection requests
> from the guest operating system."* — [VZVirtioSocketListener](
> https://developer.apple.com/documentation/virtualization/vzvirtiosocketlistener)

This is the Apple-sanctioned direction for guest-pushed streams.
`VZVirtioSocketDevice.connect(toPort:)` in the opposite direction
silently no-ops if the guest isn't listening yet — the classic
"empty chart after fresh boot" we had before this migration.

## What the Linux agent emits

Currently `GuestEvent.stats(GuestStatsResponse)` once per second.
Sources:

| Metric | Linux source |
|---|---|
| `cpuUsage`        | `/proc/stat` tick delta |
| `memoryUsedBytes` | `/proc/meminfo` (`MemTotal - MemAvailable`) |
| `memoryTotalBytes`| `/proc/meminfo` (`MemTotal`) |
| `loadAverage1m`   | `/proc/loadavg` |
| `processCount`    | count of numeric `/proc/<pid>` entries |
| `uptime`          | `/proc/uptime` |

Adding ports / apps-frontmost frames is straightforward — same
NDJSON envelope, new topic case in `HostDialer.pumpUntilDisconnect`.

## Build

Inside the Linux guest:

```bash
# One-time: install Swift if missing
sudo dnf install -y swift-lang           # Fedora 41+
# or https://swift.org/install/linux/ for other distros

git clone https://github.com/Spooky-Labs/spooktacular.git
cd spooktacular/LinuxAgent
swift build -c release
```

Produces `.build/release/spooktacular-agent` (~10 MB).

## Install

```bash
sudo ./install-in-guest.sh
```

Which copies the binary to `/usr/local/bin/spooktacular-agent`
and runs `--install-unit` to drop a systemd service at
`/etc/systemd/system/spooktacular-agent.service` +
`systemctl enable --now`.

Verify:

```bash
systemctl status spooktacular-agent
journalctl -u   spooktacular-agent -f
```

The host's workspace chart should start populating within one
second of the service's first successful `connect()`.

## Why a separate SwiftPM package

The main repo's `Package.swift` targets `.macOS("26.0")` and
imports `Virtualization`, `AppKit`, `Security`, `CryptoKit`,
and `os` — none of which are available on Linux. Isolating the
Linux agent:

- `swift build` in the repo root stays Apple-only.
- The Linux build has a clean dep graph: Foundation + Glibc +
  a 6-line C shim for `<linux/vm_sockets.h>`.
- No `#if os(Linux)` rot threads through the main codebase.

Wire-protocol parity is hand-maintained: the Linux agent's
`Stats` struct (in `HostDialer.swift`) has the same field names
and types as `GuestStatsResponse` in the main repo's
`SpooktacularCore`, and both use a `{topic, data}` envelope to
match `GuestEvent`'s Codable synthesis.
