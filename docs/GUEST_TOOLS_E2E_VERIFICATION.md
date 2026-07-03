# Guest Tools End-to-End Verification

Step-by-step checklist for verifying the Spooktacular Guest Tools install + SPICE clipboard bridge + event-driven status pill work end-to-end on a real macOS guest VM. Pairs with task #61.

## Prereqs

- Apple Silicon Mac (SIP + FileVault fine) running macOS 26 or later
- Apple Developer ID identity + valid provisioning profile (see `scripts/find-provisioning-profile.sh`)
- Enough disk for a ~64 GiB macOS VM data volume

## Build + Install

### 1. Produce a signed bundle

```bash
./build-app.sh release
```

Expected output:

- `Spooktacular.app` written to the repo root
- `Contents/Applications/Spooktacular Guest Tools.app` nested inside, co-signed
- `codesign --verify --deep --strict --verbose=2 Spooktacular.app/Contents/Applications/Spooktacular\ Guest\ Tools.app` reports "valid on disk" and "satisfies its Designated Requirement"

Manual check:

```bash
codesign -d --entitlements - "Spooktacular.app/Contents/Applications/Spooktacular Guest Tools.app"
```

Must list:
- `com.apple.application-identifier = 4AM5US9G8B.com.spooktacular.GuestTools`
- `com.apple.security.app-sandbox = true`
- `com.apple.security.network.server = true`
- `com.apple.security.temporary-exception.files.absolute-path.read-write = [/dev/tty.com.redhat.spice.0]`

### 2. Launch the host app

```bash
open Spooktacular.app
```

Expected: GUI opens, no Dock-tile-rendering weirdness from the nested bundle.

## Create a VM With Guest Tools

### 3. Create via CLI

`GuestToolsInstallMode` only has two cases today — `disabled` and
`installed`; there is no auto-launch install mode. Launch-at-login is
owned entirely by the Guest Tools app itself (`SMAppService.mainApp`
from its own menu-bar UI), never by the host installer — the host
never writes to `/Library/LaunchAgents/` and never prompts for an
admin password during install (`DiskInjector.installGuestTools`).

```bash
./Spooktacular.app/Contents/MacOS/spook create clipboard-test --guest-tools installed
```

Expected output lines:

- `Installing Spooktacular Guest Tools into guest...`
- `✓ Guest Tools installed (Install Guest Tools).`

No admin password prompt during this step — `ditto`-ing the `.app`
into the guest's mounted data volume needs no elevated privileges on
the host side.

### 4. Start the VM

```bash
./Spooktacular.app/Contents/MacOS/spook start clipboard-test
```

Expected boot sequence (visible in the GUI workspace window):

1. Apple logo + progress bar during initial install (this is the IPSW flow, ~15 min)
2. Setup Assistant — walk through country/language/user creation
3. **After completing Setup Assistant:** `Spooktacular Guest Tools.app` is present in `/Applications/` but not yet running — open it manually once inside the guest. The menu bar gains a `clipboard` icon only after this manual launch.

## Verify the Pieces

### 5. Inside the VM — Guest Tools installed

Open Terminal inside the guest:

```bash
ls /Applications/ | grep -i spooktacular
# → Spooktacular Guest Tools.app
```

The app must exist. `DiskInjector.installGuestTools` never writes to
`/Library/LaunchAgents/` for any install mode — there is no
LaunchAgent plist to check.

### 6. Inside the VM — menu-bar app running

Open `Spooktacular Guest Tools.app` manually once (Finder or
Spotlight) — nothing launches it automatically. After that:

Menu bar must show a clipboard SF Symbol with status tint:
- Gray clipboard + "Clipboard bridge: not running" — briefly at startup
- Green `clipboard.fill` + "Clipboard bridge: connected" — steady state

Click the icon. Menu must contain:
- Status line
- `Launch at Login` toggle (initially off, flip it on; macOS prompts for System Settings > General > Login Items approval)
- Restart / About / Quit

### 7. Host side — workspace toolbar pill

In the host Spooktacular GUI, open the workspace window for `clipboard-test`. The leading toolbar item must be the `ClipboardStatusPill`:

- Renders `clipboard.fill` in green
- Tooltip: "Clipboard is bridged between host and guest via SPICE vd_agent."

### 8. Event-driven transitions

Inside the guest, from the menu bar: **Restart Clipboard Bridge**.

Host side (within <1 s, no polling delay): the pill flashes through:
- orange `clipboard.fill` "Connecting…"
- green `clipboard.fill` "Clipboard shared"

### 9. Host → guest clipboard

Host: copy `Hello from host` (⌘C in any app).

Inside guest Terminal: `pbpaste` must print `Hello from host`.

### 10. Guest → host clipboard

Inside guest: `echo "Hello from guest" | pbcopy`.

Host Terminal: `pbpaste` must print `Hello from guest`.

### 11. Event stream health (optional deep probe)

`spook remote` and the guest-agent HTTP/vsock RPC surface it talked
to (`GuestAgentClient`, `GET /api/v1/spice/status`) were removed in
the descope — there is no CLI equivalent today. `spook stream`'s
topics (`metrics`, `lifecycle`, `ports`, `health`, `log`) do not
include clipboard/SPICE status, so it isn't a substitute either.
Verify event-stream health via the GUI workspace pill (steps 7–8)
instead.

## Negative checks

### 12. Two-way picker: `.disabled`

```bash
./Spooktacular.app/Contents/MacOS/spook create bare-vm --guest-tools disabled
./Spooktacular.app/Contents/MacOS/spook start bare-vm
```

Inside the guest:
```bash
ls /Applications/ | grep -i spooktacular
# → (empty)
ls /Library/LaunchAgents/ | grep -i spooktacular
# → (empty)
```

Host workspace pill renders gray "Clipboard: not active" with the install-guide tooltip.

### 13. Two-way picker: `.installed` (no auto-launch)

```bash
./Spooktacular.app/Contents/MacOS/spook create manual-vm --guest-tools installed
./Spooktacular.app/Contents/MacOS/spook start manual-vm
```

Inside the guest:
- App exists in `/Applications/`
- LaunchAgent plist does NOT exist
- Menu bar has no clipboard icon until the user launches the app manually

After manually launching the app once, it calls `SMAppService.mainApp.register()` — a System Settings "Login Items" toggle for "Spooktacular Guest Tools" must appear.

### 14. Workspace button: install retroactively

On the `bare-vm` created in step 12:
1. Stop the VM (`spook stop bare-vm`)
2. In the GUI sidebar, click the VM → Detail view → "Install Guest Tools" button
3. Wait for "Guest Tools installed" banner
4. Start the VM
5. Repeat verification steps 5–10

## Known issues / intentional quirks

- **The menu-bar app uses `SMAppService.mainApp`.** First-time users see macOS's "X wants to run in the background" dialog. Approving makes future logins fully automatic. There is no automatic first-launch — the user must open `Spooktacular Guest Tools.app` manually once.
- **No admin password prompt on install.** `DiskInjector.installGuestTools` only `ditto`s the `.app` onto the guest's mounted data volume — it never writes to `/Library/LaunchAgents/` and never shells out to `osascript`, for either `disabled` or `installed` mode.
- **`spook stop` latency on clipboard status.** When a VM stops, `AppState.clipboardStatuses[name]` is cleared. The pill in any still-open workspace window then falls back to gray "not active" until the VM restarts.

## Regression ownership

Any failure in steps 5–10 implicates:
- `Sources/SpooktacularInfrastructureApple/DiskInjector.swift` (install path)
- `Sources/SpooktacularGuestTools/*` (in-guest app lifecycle)
- `Sources/SpooktacularInfrastructureApple/AgentEventListener.swift` (host-side vsock event listener)
- `Sources/Spooktacular/AppState.swift` `.spiceStatus` dispatch case
- `Sources/Spooktacular/ClipboardStatusPill.swift` (rendering)

> Note: the guest-side event *producer* that used to dial the host
> listener (`spooktacular-agent`'s `HostEventDialer`) was deleted in
> the descope and has not been replaced yet — see CHANGELOG
> `[Unreleased]`'s Guest Tools replatform checkpoint. Until a producer
> exists again, `GuestEvent.spiceStatus` has no sender and the
> workspace pill in steps 7–8 will not transition off "not active."

Capture the specific step that failed plus the guest-side Console app output for `com.spooktacular.agent` and `com.spooktacular.app.clipboard` subsystems.
