# Native Guest Provisioning on macOS 27 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Setup Assistant OCR automation with Apple's native `VZMacGuestProvisioningOptions` (macOS 27+) so an ephemeral macOS VM boots unattended with an admin account and Setup Assistant skipped, and a single injected root LaunchDaemon runs `first-boot.sh` locally (no SSH, no MDM, no OCR).

**Architecture:** Framework-native account creation via `VZMacGuestProvisioningOptions` set on the first post-install boot; per-VM `first-boot.sh` executed by one static root LaunchDaemon injected into the image before first boot (root chown handled by a `PrivilegedFileOps` seam — direct when the host runs as root). Build the new path behind the create flow, prove it live on a macOS 27 guest, THEN delete the OCR/pkg surface.

**Tech Stack:** Swift 6 / SwiftPM, Virtualization.framework (macOS 27 SDK), Security (`SecRandomCopyBytes`), launchd, `diskutil`/`mount_virtiofs`, `sysadminctl`/`id` (guest side, in `first-boot.sh`).

## Global Constraints

- **Guest OS floor: macOS 27+.** Older guests silently ignore provisioning options. No compat hedge — the OCR path is deleted (Phase 4), not retained.
- **Host OS floor for setting options: macOS 27+.** `setGuestProvisioningOptions` / `VZMacGuestProvisioningOptions` are `API_AVAILABLE(macos(27.0))`; gate with `if #available(macOS 27, *)`.
- **`VZMacGuestProvisioningOptions` verified property surface** (from macOS 27.0 SDK header): `fullName: String`, `username: String`, `password: String`, `logsInAutomatically: Bool`, `enablesRemoteLogin: Bool`. Attach via `VZMacOSVirtualMachineStartOptions.setGuestProvisioningOptions(_:error:)`; evaluated only on first boot after restore.
- **Defaults:** `logsInAutomatically = true` (runner + remote desktop); `enablesRemoteLogin = false` (LaunchDaemon path needs no SSH).
- **Provisioning trigger is non-SSH:** the injected root LaunchDaemon runs `first-boot.sh` locally.
- **Root ownership:** injecting a `root:wheel` LaunchDaemon requires a root file op on the host. `DirectPrivilegedFileOps` is used when `geteuid() == 0`; otherwise fail fast with an actionable error. (SMAppService helper for laptops is out of scope for this plan.)
- **Verify-before-delete:** the beta-API live verification (Phase 1 + Phase 3) must pass before Phase 4 deletes the OCR path.
- No force-unwraps on Optionals; DocC on new public API; TDD for unit-testable logic; `swift build` + `swift test --parallel --skip SpooktacularUITests` green before each commit; `swiftlint --strict --quiet` exit 0. Commit trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## File Structure

- Create `Sources/SpooktacularCore/GuestProvisioningSpec.swift` — Foundation-only domain value type + validation error.
- Create `Sources/SpooktacularInfrastructureApple/GuestProvisioningOptionsMapping.swift` — `GuestProvisioningSpec → VZMacGuestProvisioningOptions` + ephemeral password generation.
- Create `Sources/SpooktacularInfrastructureApple/PrivilegedFileOps.swift` — protocol + `DirectPrivilegedFileOps`.
- Modify `Sources/SpooktacularInfrastructureApple/VirtualMachine.swift` — `start(...)` gains `guestProvisioning:`.
- Modify `Sources/SpooktacularInfrastructureApple/DiskInjector.swift` — add `installProvisionerDaemon(into:privileged:assets:)`.
- Create `Sources/SpooktacularApplication/ProvisionerAssets.swift` — locate the bundled provisioner plist + runner script.
- Modify `Sources/spooktacular-cli/Commands/Create.swift` and `Sources/Spooktacular/AppState.swift` — wire spec + daemon injection into the runner create flow.
- Tests under `Tests/SpooktacularKitTests/`.
- Phase 4 deletes: `SetupAutomation.swift`, `SetupAutomationExecutor.swift`, `VZKeyboardDriver.swift`, `VZScreenReader.swift`, `ScreenReader.swift`, `KeyboardDriver.swift`, `ProvisionerInstaller.swift`, `Resources/SpookProvisioner/postinstall`, and their tests + `build-app.sh` pkg assembly.

---

## Phase 1 — Verify the beta API on a macOS 27 guest (GATE)

### Task 1: Confirm `VZMacGuestProvisioningOptions` behavior on a live macOS 27 guest

**Files:** none committed to `Sources/` (throwaway harness); append evidence to `docs/superpowers/specs/2026-07-10-guest-provisioning-macos27-design.md` under a new "## Verification results" section.

**Interfaces:** Produces the empirical facts every later task assumes: created user is admin; Setup Assistant is skipped; SSH/auto-login behave; framework provisioning + a `RunAtLoad` LaunchDaemon coexist on first boot.

- [ ] **Step 1: Confirm host + SDK.** Run: `sw_vers -productVersion` (expect 27.x) and `xcrun --sdk macosx --show-sdk-version` (expect 27.0). If host < 27, STOP and report — this plan cannot proceed.
- [ ] **Step 2: Download a macOS 27 guest IPSW.** Only 26.4.1 is cached. In a scratch Swift snippet (or `mcp__xcode__RunCodeSnippet`), call `VZMacOSRestoreImage.latestSupported` and download `restoreImage.url` to `~/.spooktacular/cache/ipsw/`. Confirm `operatingSystemVersion.majorVersion == 27`. Expected: a ~19GB `.ipsw` on disk.
- [ ] **Step 3: Write a throwaway harness** (`/tmp/vz27probe/main.swift`, not committed) that: installs macOS 27 into a temp bundle via `VZMacOSInstaller`; then builds `VZMacOSVirtualMachineStartOptions`, sets `VZMacGuestProvisioningOptions(username: "probe", password: "Probe-<random>", fullName: "Probe", logsInAutomatically: true, enablesRemoteLogin: true)` via `setGuestProvisioningOptions(_:error:)`; starts the VM headless. Sign with the `com.apple.security.virtualization` entitlement (copy `Spooktacular.entitlements`).
- [ ] **Step 4: Observe first boot.** Give it ~10 min. Confirm via the VM console / `spook ip`-style DHCP lease + `ssh probe@<ip>`:
  - `id probe` shows membership in `admin` and `sudo -v` succeeds → **user is admin**;
  - the VM did NOT stall at Setup Assistant (SSH reachable / auto-login session present);
  - `enablesRemoteLogin` actually enabled sshd.
- [ ] **Step 5: Confirm daemon coexistence.** Before Step 3's boot, also inject a trivial `RunAtLoad` LaunchDaemon (root:wheel) that `touch`es `/var/tmp/spook-daemon-ran` and logs `id`. After boot, SSH in and confirm `/var/tmp/spook-daemon-ran` exists → the framework account-creation and a `RunAtLoad` daemon coexist. Note whether the daemon fired before/after the account existed (informs the `first-boot.sh` account-wait).
- [ ] **Step 6: Record + tear down.** Append the confirmed/failed facts to the spec's "Verification results" section (this is the gate for Phase 4). `rm -rf` the probe bundle. Commit the spec update: `docs(spec): record macOS 27 guest-provisioning verification results`.

**If any Step-4 assumption fails**, STOP and report — the design needs revising before proceeding.

---

## Phase 2 — Build the new provisioning path

### Task 2: `GuestProvisioningSpec` domain type

**Files:**
- Create: `Sources/SpooktacularCore/GuestProvisioningSpec.swift`
- Test: `Tests/SpooktacularKitTests/GuestProvisioningSpecTests.swift`

**Interfaces:**
- Produces: `GuestProvisioningSpec` (struct) with `fullName`, `username`, `password`, `logsInAutomatically`, `enablesRemoteLogin: Bool`; `func validated() throws -> GuestProvisioningSpec`; `enum GuestProvisioningError: Error, Equatable`.

- [ ] **Step 1: Write the failing test.**

```swift
import Testing
@testable import SpooktacularCore

@Suite("GuestProvisioningSpec")
struct GuestProvisioningSpecTests {
    @Test("defaults: auto-login on, SSH off")
    func defaults() {
        let s = GuestProvisioningSpec(fullName: "Spooktacular Runner", username: "runner", password: "abcdEFGH1234")
        #expect(s.logsInAutomatically == true)
        #expect(s.enablesRemoteLogin == false)
    }

    @Test("validated rejects empty username")
    func emptyUsername() {
        let s = GuestProvisioningSpec(fullName: "R", username: "", password: "abcdEFGH1234")
        #expect(throws: GuestProvisioningError.emptyUsername) { try s.validated() }
    }

    @Test("validated rejects short password")
    func shortPassword() {
        let s = GuestProvisioningSpec(fullName: "R", username: "runner", password: "short")
        #expect(throws: GuestProvisioningError.passwordTooShort) { try s.validated() }
    }

    @Test("validated passes a well-formed spec")
    func valid() throws {
        let s = GuestProvisioningSpec(fullName: "R", username: "runner", password: "abcdEFGH1234")
        #expect(try s.validated() == s)
    }
}
```

- [ ] **Step 2: Run test to verify it fails.** Run: `swift test --filter GuestProvisioningSpec` → FAIL ("cannot find 'GuestProvisioningSpec'").
- [ ] **Step 3: Write minimal implementation.**

```swift
import Foundation

/// Describes the account and setup preferences to apply to a fresh macOS
/// guest via `VZMacGuestProvisioningOptions` on first boot after restore.
///
/// Foundation-only domain value type; the mapping to the Virtualization
/// framework type lives in `SpooktacularInfrastructureApple`.
public struct GuestProvisioningSpec: Sendable, Equatable {
    /// The account's full (display) name.
    public var fullName: String
    /// The short login name (e.g. `runner`).
    public var username: String
    /// The account password. Ephemeral, generated per-VM.
    public var password: String
    /// Whether the guest auto-logs-in the account at startup. Defaults to `true`.
    public var logsInAutomatically: Bool
    /// Whether the guest enables Remote Login (SSH). Defaults to `false`.
    public var enablesRemoteLogin: Bool

    public init(
        fullName: String,
        username: String,
        password: String,
        logsInAutomatically: Bool = true,
        enablesRemoteLogin: Bool = false
    ) {
        self.fullName = fullName
        self.username = username
        self.password = password
        self.logsInAutomatically = logsInAutomatically
        self.enablesRemoteLogin = enablesRemoteLogin
    }

    /// Returns the spec unchanged if valid; otherwise throws.
    public func validated() throws -> GuestProvisioningSpec {
        guard !username.isEmpty else { throw GuestProvisioningError.emptyUsername }
        guard password.count >= 8 else { throw GuestProvisioningError.passwordTooShort }
        return self
    }
}

/// Errors from validating a ``GuestProvisioningSpec``.
public enum GuestProvisioningError: Error, Equatable {
    /// The username was empty.
    case emptyUsername
    /// The password was shorter than the 8-character minimum.
    case passwordTooShort
}
```

- [ ] **Step 4: Run test to verify it passes.** Run: `swift test --filter GuestProvisioningSpec` → PASS (4 tests).
- [ ] **Step 5: Commit.** `git add Sources/SpooktacularCore/GuestProvisioningSpec.swift Tests/SpooktacularKitTests/GuestProvisioningSpecTests.swift && git commit -m "feat(provisioning): GuestProvisioningSpec domain type"`

### Task 3: Spec→`VZMacGuestProvisioningOptions` mapping + ephemeral password

**Files:**
- Create: `Sources/SpooktacularInfrastructureApple/GuestProvisioningOptionsMapping.swift`
- Test: `Tests/SpooktacularKitTests/GuestProvisioningOptionsMappingTests.swift`

**Interfaces:**
- Consumes: `GuestProvisioningSpec` (Task 2).
- Produces: `enum EphemeralCredential { static func generatePassword(length: Int = 24) -> String }`; `@available(macOS 27, *) func makeGuestProvisioningOptions(from spec: GuestProvisioningSpec) -> VZMacGuestProvisioningOptions`.

- [ ] **Step 1: Write the failing test.** (The mapping test is gated on macOS 27 at runtime; the password test always runs.)

```swift
import Testing
import Foundation
@testable import SpooktacularInfrastructureApple
import SpooktacularCore

@Suite("GuestProvisioningOptionsMapping")
struct GuestProvisioningOptionsMappingTests {
    @Test("generated password is long and non-trivial")
    func password() {
        let p = EphemeralCredential.generatePassword()
        #expect(p.count >= 24)
        #expect(p != EphemeralCredential.generatePassword())  // effectively never equal
    }

    @available(macOS 27, *)
    @Test("spec maps onto VZMacGuestProvisioningOptions fields")
    func mapping() {
        let spec = GuestProvisioningSpec(
            fullName: "Spooktacular Runner", username: "runner",
            password: "abcdEFGH1234", logsInAutomatically: true, enablesRemoteLogin: false
        )
        let opts = makeGuestProvisioningOptions(from: spec)
        #expect(opts.username == "runner")
        #expect(opts.fullName == "Spooktacular Runner")
        #expect(opts.password == "abcdEFGH1234")
        #expect(opts.logsInAutomatically == true)
        #expect(opts.enablesRemoteLogin == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails.** Run: `swift test --filter GuestProvisioningOptionsMapping` → FAIL.
- [ ] **Step 3: Write minimal implementation.**

```swift
import Foundation
import Security
import Virtualization
import SpooktacularCore

/// Generates ephemeral credentials for guest provisioning.
public enum EphemeralCredential {
    /// Returns a random alphanumeric password of the given length using the
    /// system CSPRNG. Alphanumeric-only to avoid shell/quoting hazards when the
    /// value flows through `first-boot.sh`.
    public static func generatePassword(length: Int = 24) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }
}

/// Maps a domain ``GuestProvisioningSpec`` onto the Virtualization framework's
/// `VZMacGuestProvisioningOptions` (macOS 27+).
@available(macOS 27, *)
public func makeGuestProvisioningOptions(
    from spec: GuestProvisioningSpec
) -> VZMacGuestProvisioningOptions {
    let opts = VZMacGuestProvisioningOptions()
    opts.fullName = spec.fullName
    opts.username = spec.username
    opts.password = spec.password
    opts.logsInAutomatically = spec.logsInAutomatically
    opts.enablesRemoteLogin = spec.enablesRemoteLogin
    return opts
}
```

- [ ] **Step 4: Run test to verify it passes.** Run: `swift test --filter GuestProvisioningOptionsMapping` → PASS (on a macOS 27 host both tests run; the mapping test is skipped by availability on older hosts).
- [ ] **Step 5: Commit.** `git commit -am "feat(provisioning): spec→VZMacGuestProvisioningOptions mapping + ephemeral password"`

### Task 4: `PrivilegedFileOps` seam + `DirectPrivilegedFileOps`

**Files:**
- Create: `Sources/SpooktacularInfrastructureApple/PrivilegedFileOps.swift`
- Test: `Tests/SpooktacularKitTests/PrivilegedFileOpsTests.swift`

**Interfaces:**
- Produces: `protocol PrivilegedFileOps: Sendable { func preflight() throws; func makeDirectory(at: URL) throws; func installFile(from: URL, to: URL, mode: mode_t) throws }`; `struct DirectPrivilegedFileOps: PrivilegedFileOps` (requires `geteuid() == 0`, else throws `.notPrivileged`); `enum PrivilegedOpsError: Error, Equatable { case notPrivileged }`. `preflight()` is the cheap "am I able to do privileged ops?" check callers run before expensive work (e.g. disk mounting).

- [ ] **Step 1: Write the failing test.** (Root-requiring assertions run only when the test itself is root; the not-privileged path is always tested by faking euid via a seam.)

```swift
import Testing
import Foundation
@testable import SpooktacularInfrastructureApple

@Suite("PrivilegedFileOps")
struct PrivilegedFileOpsTests {
    @Test("preflight + ops throw notPrivileged when not root")
    func notRoot() {
        let ops = DirectPrivilegedFileOps(effectiveUID: { 501 })  // pretend non-root
        #expect(throws: PrivilegedOpsError.notPrivileged) { try ops.preflight() }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("x")
        #expect(throws: PrivilegedOpsError.notPrivileged) { try ops.makeDirectory(at: tmp) }
    }

    @Test("Direct ops installFile copies + chmods when 'root'")
    func installsFile() throws {
        // effectiveUID stubbed to 0 so the guard passes; chown to root is a
        // no-op we skip when the real process isn't root (see impl note).
        let ops = DirectPrivilegedFileOps(effectiveUID: { 0 }, skipChownWhenNotRoot: true)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("plist"); try "x".write(to: src, atomically: true, encoding: .utf8)
        let dst = dir.appendingPathComponent("out.plist")
        try ops.installFile(from: src, to: dst, mode: 0o644)
        #expect(FileManager.default.fileExists(atPath: dst.path))
        let perms = try FileManager.default.attributesOfItem(atPath: dst.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o644)
    }
}
```

- [ ] **Step 2: Run test to verify it fails.** Run: `swift test --filter PrivilegedFileOps` → FAIL.
- [ ] **Step 3: Write minimal implementation.**

```swift
import Foundation

/// Errors from privileged file operations.
public enum PrivilegedOpsError: Error, Equatable {
    /// The process lacks the root privilege required to set `root:wheel` ownership.
    case notPrivileged
}

/// Performs the root-owned file operations needed to inject a LaunchDaemon into
/// a guest volume: create directories and install files owned `root:wheel`.
public protocol PrivilegedFileOps: Sendable {
    /// Cheap check that privileged ops are possible; throws if not. Callers run
    /// this before expensive work (e.g. mounting a disk image) so a
    /// non-privileged run fails fast.
    func preflight() throws
    /// Creates `url` (and parents), owned `root:wheel`, mode 0755.
    func makeDirectory(at url: URL) throws
    /// Copies `src` to `dst`, then sets ownership `root:wheel` and the given mode.
    func installFile(from src: URL, to dst: URL, mode: mode_t) throws
}

/// `PrivilegedFileOps` for a process already running as root (EC2 Mac or under a
/// root LaunchDaemon). Throws ``PrivilegedOpsError/notPrivileged`` when not root.
public struct DirectPrivilegedFileOps: PrivilegedFileOps {
    private let effectiveUID: @Sendable () -> uid_t
    private let skipChownWhenNotRoot: Bool

    /// - Parameters:
    ///   - effectiveUID: Seam for testing; defaults to `geteuid`.
    ///   - skipChownWhenNotRoot: When true, skips the real `chown(0,0)` if the
    ///     process isn't actually root (used by tests that stub `effectiveUID`).
    public init(
        effectiveUID: @escaping @Sendable () -> uid_t = { geteuid() },
        skipChownWhenNotRoot: Bool = false
    ) {
        self.effectiveUID = effectiveUID
        self.skipChownWhenNotRoot = skipChownWhenNotRoot
    }

    private func requireRoot() throws {
        guard effectiveUID() == 0 else { throw PrivilegedOpsError.notPrivileged }
    }

    public func preflight() throws { try requireRoot() }

    public func makeDirectory(at url: URL) throws {
        try requireRoot()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try chownRoot(url); try chmod(url, 0o755)
    }

    public func installFile(from src: URL, to dst: URL, mode: mode_t) throws {
        try requireRoot()
        if FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.removeItem(at: dst)
        }
        try FileManager.default.copyItem(at: src, to: dst)
        try chownRoot(dst); try chmod(dst, mode)
    }

    private func chownRoot(_ url: URL) throws {
        if skipChownWhenNotRoot && geteuid() != 0 { return }
        if chown(url.path, 0, 0) != 0 { throw errno_error() }
    }
    private func chmod(_ url: URL, _ mode: mode_t) throws {
        if Foundation.chmod(url.path, mode) != 0 { throw errno_error() }
    }
    private func errno_error() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
    }
}
```

- [ ] **Step 4: Run test to verify it passes.** Run: `swift test --filter PrivilegedFileOps` → PASS.
- [ ] **Step 5: Commit.** `git commit -am "feat(provisioning): PrivilegedFileOps seam + DirectPrivilegedFileOps"`

### Task 5: Provisioner asset locator + image-injection variant of the plist/runner

**Files:**
- Create: `Sources/SpooktacularApplication/ProvisionerAssets.swift`
- Modify: `Resources/SpookProvisioner/spook-provision-runner.sh` (add a bounded wait for the provisioning account before running `first-boot.sh`); keep `com.spookylabs.spooktacular.provisioner.plist` as-is (Program path unchanged).
- Test: `Tests/SpooktacularKitTests/ProvisionerAssetsTests.swift`

**Interfaces:**
- Produces: `enum ProvisionerAssets { static func locate() -> (plist: URL, runner: URL)? }` — returns the bundled plist + runner-script URLs from the app bundle, or `nil` in a plain `swift test` context (mirrors `AppBundleBootstrapTemplate.locateGuestToolsBundle()`); read that existing locator first and follow its resolution pattern.

- [ ] **Step 1: Read the existing locator.** Read `Sources/SpooktacularApplication/AppBundleBootstrapTemplate.swift` for `locateGuestToolsBundle()` — copy its bundle-resolution approach (search `Bundle.main` resource paths, tolerate absence in unit tests). Reuse the resolution logic; do not invent a new mechanism.
- [ ] **Step 2: Write the failing test.**

```swift
import Testing
import Foundation
@testable import SpooktacularApplication

@Suite("ProvisionerAssets")
struct ProvisionerAssetsTests {
    @Test("locate returns nil outside an app bundle (unit-test context)")
    func nilOutsideBundle() {
        // In `swift test` there is no app bundle with the provisioner resources.
        #expect(ProvisionerAssets.locate() == nil)
    }
}
```

- [ ] **Step 3: Run test to verify it fails.** Run: `swift test --filter ProvisionerAssets` → FAIL.
- [ ] **Step 4: Implement `ProvisionerAssets.locate()`** following the `AppBundleBootstrapTemplate` pattern, returning the URLs to `com.spookylabs.spooktacular.provisioner.plist` and `spook-provision-runner.sh` bundled under the app's `Resources/SpookProvisioner/` (built there by `build-app.sh`), or `nil` when not found. Full DocC on the type + method.
- [ ] **Step 5: Add the account-wait to `spook-provision-runner.sh`.** Before executing `first-boot.sh`, insert a bounded wait so the runner script doesn't race the framework's account creation:

```bash
# The framework creates the provisioning account (VZMacGuestProvisioningOptions)
# during early boot; this RunAtLoad daemon can fire before it exists. Wait
# (bounded) for the account before running the user script, which may sudo -u it.
RUNNER_USER="${SPOOK_PROVISION_USER:-runner}"
for _ in $(seq 1 60); do id "$RUNNER_USER" >/dev/null 2>&1 && break; sleep 2; done
```

- [ ] **Step 6: Run test + shell lint.** Run: `swift test --filter ProvisionerAssets` → PASS; `bash -n Resources/SpookProvisioner/spook-provision-runner.sh` → exit 0.
- [ ] **Step 7: Commit.** `git commit -am "feat(provisioning): ProvisionerAssets locator + account-wait in runner script"`

### Task 6: `DiskInjector.installProvisionerDaemon`

**Files:**
- Modify: `Sources/SpooktacularInfrastructureApple/DiskInjector.swift`
- Test: `Tests/SpooktacularKitTests/DiskInjectorProvisionerTests.swift`

**Interfaces:**
- Consumes: `PrivilegedFileOps` (Task 4), `ProvisionerAssets` URLs (Task 5), `VirtualMachineBundle`, and `DiskInjector`'s existing `runProcess`/`parseDeviceFromPlist`/`ensureDataVolume`/`mountDataVolume` helpers.
- Produces: `public static func installProvisionerDaemon(into bundle: VirtualMachineBundle, plist: URL, runner: URL, privileged: PrivilegedFileOps) throws` — attaches `disk.img`, mounts the Data volume, installs the runner script to `<vol>/usr/local/libexec/spook-provision-runner.sh` (0755) and the plist to `<vol>/Library/LaunchDaemons/com.spookylabs.spooktacular.provisioner.plist` (0644), both `root:wheel` via `privileged`, then detaches. Reuses the attach/mount/detach pattern from `installGuestTools`.

- [ ] **Step 1: Write the failing test.** The disk-mount path needs a real image, so the unit test asserts the *non-privileged guard* (fast, no disk): calling with a `DirectPrivilegedFileOps` that reports non-root surfaces `PrivilegedOpsError.notPrivileged` before any disk work — verify by pointing at a bundle whose `disk.img` is absent and asserting the privileged error is thrown, not `diskImageNotFound`. Structure the method to check `privileged` readiness first.

```swift
import Testing
import Foundation
@testable import SpooktacularInfrastructureApple

@Suite("DiskInjector provisioner")
struct DiskInjectorProvisionerTests {
    @Test("installProvisionerDaemon fails fast when not privileged")
    func notPrivileged() throws {
        let bundleDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".vm")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        let bundle = VirtualMachineBundle(url: bundleDir)   // no disk.img present
        let src = bundleDir.appendingPathComponent("f"); try "x".write(to: src, atomically: true, encoding: .utf8)
        let ops = DirectPrivilegedFileOps(effectiveUID: { 501 })
        #expect(throws: PrivilegedOpsError.notPrivileged) {
            try DiskInjector.installProvisionerDaemon(into: bundle, plist: src, runner: src, privileged: ops)
        }
    }
}
```
(If `VirtualMachineBundle(url:)` differs, read its initializer and adapt the construction; keep the intent — non-privileged fails before disk work.)

- [ ] **Step 2: Run test to verify it fails.** Run: `swift test --filter "DiskInjector provisioner"` → FAIL.
- [ ] **Step 3: Implement `installProvisionerDaemon`.** Read `installGuestTools` (lines ~69–133) for the attach/`ensureDataVolume`/`ditto`/detach pattern. Structure the method so it **calls `privileged.preflight()` as its very first statement** (defined in Task 4's protocol) — so a non-root run throws `PrivilegedOpsError.notPrivileged` before any disk work. Then: attach `disk.img`, mount the Data volume (`ensureDataVolume`/`mountDataVolume`), `privileged.makeDirectory(at: <vol>/usr/local/libexec)`, `privileged.installFile(from: runner, to: <vol>/usr/local/libexec/spook-provision-runner.sh, mode: 0o755)`, `privileged.installFile(from: plist, to: <vol>/Library/LaunchDaemons/com.spookylabs.spooktacular.provisioner.plist, mode: 0o644)`, detach in `defer`. Full DocC.
- [ ] **Step 4: Run test to verify it passes.** Run: `swift test --filter "DiskInjector provisioner"` → PASS. Then full suite: `swift test --parallel --skip SpooktacularUITests` → green.
- [ ] **Step 5: Commit.** `git commit -am "feat(provisioning): DiskInjector.installProvisionerDaemon (image-time root LaunchDaemon)"`

### Task 7: `VirtualMachine.start(guestProvisioning:)`

**Files:**
- Modify: `Sources/SpooktacularInfrastructureApple/VirtualMachine.swift` (the `start(...)` method, ~line 314–345)
- Test: `Tests/SpooktacularKitTests/VirtualMachineStartOptionsTests.swift` (mapping-only; the actual boot is covered by live e2e)

**Interfaces:**
- Consumes: `GuestProvisioningSpec` (Task 2), `makeGuestProvisioningOptions` (Task 3).
- Produces: `public func start(startUpFromMacOSRecovery: Bool = false, guestProvisioning: GuestProvisioningSpec? = nil) async throws`. When `guestProvisioning != nil`: on macOS 27+ build `VZMacOSVirtualMachineStartOptions`, `setGuestProvisioningOptions(makeGuestProvisioningOptions(from: spec.validated()))`, and start with options; if host < macOS 27 throw `VirtualMachineProvisioningError.hostTooOld`.

- [ ] **Step 1: Write the failing test** (a pure host-version-gating test using a small extracted helper so no real VM boots):

```swift
import Testing
@testable import SpooktacularInfrastructureApple
import SpooktacularCore

@Suite("VM start provisioning options")
struct VirtualMachineStartOptionsTests {
    @available(macOS 27, *)
    @Test("builds start options carrying the provisioning account")
    func buildsOptions() throws {
        let spec = GuestProvisioningSpec(fullName: "R", username: "runner", password: "abcdEFGH1234")
        let opts = try VirtualMachine.makeStartOptions(recovery: false, provisioning: spec)
        #expect(opts.guestProvisioningOptions?.username == "runner")
    }
}
```

- [ ] **Step 2: Run test to verify it fails.** Run: `swift test --filter "VM start provisioning"` → FAIL.
- [ ] **Step 3: Implement.** Extract a testable static helper and wire it into `start`:

```swift
enum VirtualMachineProvisioningError: Error, Equatable { case hostTooOld }

// static, testable — builds the options without touching a live VM.
static func makeStartOptions(
    recovery: Bool, provisioning: GuestProvisioningSpec?
) throws -> VZMacOSVirtualMachineStartOptions {
    let options = VZMacOSVirtualMachineStartOptions()
    options.startUpFromMacOSRecovery = recovery
    if let provisioning {
        guard #available(macOS 27, *) else { throw VirtualMachineProvisioningError.hostTooOld }
        try options.setGuestProvisioningOptions(makeGuestProvisioningOptions(from: provisioning.validated()))
    }
    return options
}
```
Then change `start` to `start(startUpFromMacOSRecovery: Bool = false, guestProvisioning: GuestProvisioningSpec? = nil)`: if `guestProvisioning != nil || startUpFromMacOSRecovery`, build via `makeStartOptions` and use the `start(options:)` continuation (the existing recovery branch already shows the continuation pattern); else keep `try await unsafeVM.start()`.

- [ ] **Step 4: Run test to verify it passes.** Run: `swift test --filter "VM start provisioning"` → PASS; grep call sites of `.start(` in `Sources/` and confirm the new default param keeps them compiling; full suite green.
- [ ] **Step 5: Commit.** `git commit -am "feat(provisioning): VirtualMachine.start(guestProvisioning:) sets VZMacGuestProvisioningOptions"`

### Task 8: Wire the CLI runner create flow

**Files:**
- Modify: `Sources/spooktacular-cli/Commands/Create.swift` (runner branch)
- Test: extend `Tests/SpooktacularKitTests/RunnerCreateFlowTests.swift` if the ordering logic is extractable (prefer a small pure planner); otherwise verify via the built binary.

**Interfaces:**
- Consumes: Tasks 2–7. Produces the CLI runner flow: install macOS 27 → generate password + `GuestProvisioningSpec(username: "runner", …)` → `DiskInjector.installProvisionerDaemon(into:plist:runner:privileged: DirectPrivilegedFileOps())` (locate assets via `ProvisionerAssets.locate()`; soft-warn + skip if absent in dev) → mint token + render `first-boot.sh` + `DiskInjector.inject(script:)` (existing) → `vm.start(guestProvisioning: spec)` (first boot) → online poll (existing).

- [ ] **Step 1:** Read the current runner branch in `Create.swift` (the `automateSetupAssistant` + `provisionGitHubRunner` region). Replace the Setup-Assistant-automation call with: build `GuestProvisioningSpec`, inject the provisioner daemon (via `ProvisionerAssets.locate()` + `DirectPrivilegedFileOps()`; if `locate()` is nil, `Log.provision.warning` + continue so dev builds don't hard-fail), then start the VM with `guestProvisioning:`.
- [ ] **Step 2:** Preflight check: before install, call `DirectPrivilegedFileOps().preflight()`; if it throws, fail fast with an actionable message ("provisioner injection requires running as root; on EC2 Mac run under the root service, or `sudo spook create …`"). Do not add a `--no-provisioner-daemon` flag (YAGNI — the runner cannot provision without the daemon).
- [ ] **Step 3:** Keep the online-poll + exit-code contract unchanged. Update `Create.swift` help text: the runner flow now requires a macOS 27+ guest and provisions natively (no Setup Assistant).
- [ ] **Step 4:** Build the CLI: `swift build --product spooktacular-cli`; run `.build/debug/spooktacular-cli create --help` and confirm truthful text; full suite green; `swiftlint --strict --quiet` exit 0.
- [ ] **Step 5: Commit.** `git commit -am "feat(runner): CLI create uses native guest provisioning + injected daemon"`

### Task 9: GUI parity (`AppState.runMacOSCreate`)

**Files:**
- Modify: `Sources/Spooktacular/AppState.swift` (`runMacOSCreate` / `provisionGitHubRunnerForCreate`)
- Test: keep `Tests/SpooktacularKitTests/GuestToolsProvisioningGateTests.swift` green (do not touch the `installsAppBundle` literal it greps for).

**Interfaces:** Mirror Task 8 in the GUI pipeline: after install, generate the spec, inject the provisioner daemon, start with `guestProvisioning:`, poll online. Remove the GUI's Setup-Assistant-automation call.

- [ ] **Step 1:** Read `provisionGitHubRunnerForCreate` (added in the earlier runner work) and replace its Setup-Assistant-automation portion with the native-provisioning path (spec + daemon inject + `start(guestProvisioning:)`), surfacing stages through the existing `pendingCreations`/`updateCreation` progress.
- [ ] **Step 2:** Build the GUI target (`swift build`), full suite green, `swiftlint --strict` exit 0.
- [ ] **Step 3: Commit.** `git commit -am "feat(gui): native guest provisioning parity in AppState create pipeline"`

---

## Phase 3 — Live end-to-end on macOS 27

### Task 10: Full `spook create --github-runner` on a macOS 27 guest

**Files:** append evidence to `docs/superpowers/specs/2026-07-10-guest-provisioning-macos27-design.md` ("## E2E results"); create `.github/workflows/selfhosted-smoke.yml` if not present (`workflow_dispatch`, `runs-on: [self-hosted]`, one `echo` step).

- [ ] **Step 1:** `./build-app.sh release`; confirm the provisioner plist + runner script are bundled under the app's `Resources/SpookProvisioner/`.
- [ ] **Step 2:** Store a PAT: `security add-generic-password -s com.spooktacular.github -a e2e -w "$(gh auth token)" -U`.
- [ ] **Step 3:** Run (as root, since injection needs it): `sudo -E Spooktacular.app/Contents/MacOS/spook create runner-e2e --github-runner --github-repo Spooky-Labs/spooktacular --github-token-keychain e2e --from-ipsw ~/.spooktacular/cache/ipsw/<macOS27>.ipsw` in the background; poll the log in bounded loops (≤5 min per call). Expected stages: install → daemon injected → first boot (native provisioning, no Setup Assistant) → `first-boot.sh` runs → runner registers.
- [ ] **Step 4:** Assert online: `gh api repos/Spooky-Labs/spooktacular/actions/runners --jq '.runners[]|select(.name=="runner-e2e")|.status'` → `online`.
- [ ] **Step 5:** Dispatch + verify a job runs on it: `gh workflow run selfhosted-smoke.yml --ref feat/guest-provisioning-macos27`; watch; confirm `runnerName == "runner-e2e"` + success. This is the milestone the OCR path never reached.
- [ ] **Step 6:** Teardown (stop/delete VM, deregister runner, delete keychain item). Record the full timeline in the spec's E2E section. Commit evidence: `test(e2e): native macOS 27 guest provisioning — live runner verified`.

**Gate:** Phase 4 only proceeds if Task 10 verifies a real job on the runner.

---

## Phase 4 — Delete the OCR / pkg surface

### Task 11: Remove Setup Assistant automation + pkg provisioning

**Files:**
- Delete: `Sources/SpooktacularApplication/SetupAutomation.swift`, `Sources/SpooktacularInfrastructureApple/{SetupAutomationExecutor,VZKeyboardDriver,VZScreenReader}.swift`, `Sources/SpooktacularCore/{ScreenReader,KeyboardDriver}.swift`, `Sources/SpooktacularGuestTools/ProvisionerInstaller.swift`, `Resources/SpookProvisioner/postinstall`, and their tests (`SetupAutomation*Tests`, screen-gate tests, `VZKeyboardDriver`/`VZScreenReader` tests).
- Modify: `Sources/spooktacular-cli/Commands/Create.swift`, `Sources/Spooktacular/AppState.swift`, `Sources/SpooktacularApplication/RunnerCreateFlowPlan.swift` — remove `automateSetupAssistant`, screen-gate, and Setup-Assistant-support branches; `Sources/SpooktacularApplication/AppBundleBootstrapTemplate.swift` if it references the pkg-install path; `build-app.sh` — delete the provisioner-`pkg` assembly (`pkgbuild`/`productbuild` of `Spooktacular Provisioner.pkg`) but keep bundling the plist + runner script under `Resources/SpookProvisioner/`; `SecurityControlInventory.swift` if it cites any deleted file (path-existence test).

- [ ] **Step 1:** `grep -rn 'SetupAutomation\|SetupAutomationExecutor\|VZKeyboardDriver\|VZScreenReader\|ScreenReader\|KeyboardDriver\|ProvisionerInstaller\|automateSetupAssistant\|Provisioner.pkg' Sources/ Tests/ build-app.sh` to enumerate every reference before deleting.
- [ ] **Step 2:** Delete the files; remove every reference found in Step 1 (create-flow branches, `RunnerCreateFlowPlan` Setup-Assistant gating, `SecurityControlInventory` entries, `build-app.sh` pkg block).
- [ ] **Step 3:** `swift build` → 0 errors; `swift test --parallel --skip SpooktacularUITests` → green; `swiftlint --strict --quiet` → exit 0; `bash -n build-app.sh` → exit 0.
- [ ] **Step 4:** Re-run the grep from Step 1 → only historical/CHANGELOG hits remain.
- [ ] **Step 5: Commit.** `git commit -am "descope(provisioning): remove Setup Assistant OCR + pkg path (superseded by native macOS 27 provisioning)"`

---

## Phase 5 — Docs + CI

### Task 12: Truth pass + count sync + push + CI green

**Files:** `README.md`, `docs/get-started.html`, `Sources/SpooktacularKit/Documentation.docc/GitHubActionsGuide.md`, `CHANGELOG.md`, `docs/superpowers/specs/2026-07-10-guest-provisioning-macos27-design.md` (mark implemented).

- [ ] **Step 1:** Update the runner docs: provisioning is now native (macOS 27+ guests, no Setup Assistant); remove any OCR / Setup-Assistant references. Note the macOS 27+ guest requirement prominently.
- [ ] **Step 2:** Sync the README test count (`swift test … | grep 'Test run with'` for root + the 3 SPICE packages; update all three README sites to the new total) and run `scripts/ci/validate-readme-claims.sh` → exit 0.
- [ ] **Step 3:** `swiftlint --strict --quiet` (0), full `swift test` green, `./build-app.sh release` completes.
- [ ] **Step 4:** Push `feat/guest-provisioning-macos27`; open a PR to `main`; watch CI (`gh run watch`) until all three jobs pass; fix any residual failures.
- [ ] **Step 5: Commit + finish.** Use superpowers:finishing-a-development-branch to complete.
