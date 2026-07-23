# Cross-OS First-Boot Provisioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every provisioning template (OpenClaw, GitHub runner, custom user-data) works on macOS **and** Linux guests, CLI and GUI, with no SSH and no golden image — per `docs/superpowers/specs/2026-07-18-cross-os-provisioning-design.md`.

**Architecture:** Each OS keeps exactly one initial-script system that runs user-data as root at first boot: macOS = injected provisioner LaunchDaemon (exists; fix the OpenClaw script's root-context bug), Linux = cloud-init fed by a `cidata` seed ISO built with `hdiutil makehybrid` and attached read-only (new; rootless). Templates become OS-aware.

**Tech Stack:** Swift 6 / SPM, swift-testing (`@Test`/`#expect`), Virtualization.framework, Apple Compression framework (xz), `hdiutil`, cloud-init NoCloud, systemd (guest), launchd (guest).

## Global Constraints

- Zero third-party Swift dependencies (Apple SDKs only).
- No force-unwraps (`!`) — `guard let` + typed throw / `??` / `try #require`.
- DocC on every new public API; Apple API claims verified via `mcp__xcode__DocumentationSearch` or empirical test, cited in comments.
- No plaintext guest password at rest: Linux seeds carry only a SHA-512-crypt hash; macOS System-Keychain design is untouched.
- Latest versions resolved at runtime (Node 24.x from nodejs.org index, Fedora/Debian images from official endpoints) — never hardcoded.
- `swiftlint --strict` clean; `swift test --parallel --skip SpooktacularUITests` green before every commit.
- Commit trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` + `Claude-Session: https://claude.ai/code/session_013ovVxQ8WTFGgo92aa92PH1`.
- Out of scope (do NOT touch): greyed-picker root-cause (separate live-debug effort), SMAppService privileged helper, macOS runner flow, keychain/MFA design, Ubuntu qcow2, Remote Desktop on Linux.

---

### Task 1: SHA-512-crypt (`$6$`) in SpooktacularCore

**Files:**
- Create: `Sources/SpooktacularCore/SHA512Crypt.swift`
- Test: `Tests/SpooktacularKitTests/SHA512CryptTests.swift`

**Interfaces:**
- Produces: `public enum SHA512Crypt { public static func hash(password: String, salt: String) throws -> String; public static func generateSalt() -> String }` — output format `$6$<salt>$<86-char-b64>`, default 5000 rounds (no `rounds=` emitted). `SHA512CryptError.invalidSalt` thrown for salt > 16 chars after truncation rules or illegal chars.

- [ ] **Step 1: Write failing tests** — the two canonical vectors from Ulrich Drepper's SHA-crypt reference (https://www.akkadia.org/drepper/SHA-crypt.txt):

```swift
import Testing
@testable import SpooktacularCore

@Suite("SHA512Crypt")
struct SHA512CryptTests {
    @Test("Drepper reference vector: simple salt")
    func referenceVector1() throws {
        #expect(try SHA512Crypt.hash(password: "Hello world!", salt: "saltstring")
            == "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1")
    }
    @Test("salt longer than 16 chars is truncated to 16 (spec rule)")
    func saltTruncation() throws {
        let full = try SHA512Crypt.hash(password: "Hello world!", salt: "saltstringsaltstring")
        let sixteen = try SHA512Crypt.hash(password: "Hello world!", salt: "saltstringsaltst")
        #expect(full == sixteen)
    }
    @Test("generated salt is 16 chars from the crypt alphabet")
    func saltAlphabet() {
        let salt = SHA512Crypt.generateSalt()
        #expect(salt.count == 16)
        let allowed = Set("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        #expect(salt.allSatisfy { allowed.contains($0) })
    }
    @Test("dollar sign in salt is rejected")
    func rejectsIllegalSalt() {
        #expect(throws: SHA512CryptError.invalidSalt) {
            _ = try SHA512Crypt.hash(password: "x", salt: "bad$salt")
        }
    }
}
```

- [ ] **Step 2: Run** `swift test --filter SHA512Crypt` — expect FAIL (type not found).

- [ ] **Step 3: Implement** `SHA512Crypt.swift` — the Drepper algorithm with CryptoKit's `SHA512`. Complete implementation:

```swift
import Foundation
import CryptoKit

/// SHA-512-crypt (`$6$`, Ulrich Drepper's SHA-crypt, as used in
/// `/etc/shadow`) for cloud-init `passwd:` fields.
///
/// Implemented from the reference specification
/// <https://www.akkadia.org/drepper/SHA-crypt.txt> (steps 1–22) and
/// verified against its published test vectors — no plaintext password
/// ever lands on disk; the seed carries only this hash.
public enum SHA512Crypt {

    static let b64Alphabet = Array("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    static let rounds = 5000  // spec default; no `rounds=` prefix emitted

    /// Hashes `password` with `salt` (truncated to 16 chars per spec).
    public static func hash(password: String, salt rawSalt: String) throws -> String {
        let salt = String(rawSalt.prefix(16))
        guard !salt.isEmpty, !salt.contains("$"), !salt.contains(":") else {
            throw SHA512CryptError.invalidSalt
        }
        let pw = Array(password.utf8), st = Array(salt.utf8)

        // Steps 1–3: digest B = SHA512(pw + salt + pw)
        var b = SHA512(); b.update(data: pw); b.update(data: st); b.update(data: pw)
        let digestB = Array(b.finalize())

        // Steps 4–8: digest A = SHA512(pw + salt + repeats/bits of B)
        var a = SHA512(); a.update(data: pw); a.update(data: st)
        var remaining = pw.count
        while remaining > 64 { a.update(data: digestB); remaining -= 64 }
        a.update(data: digestB.prefix(remaining))
        var bits = pw.count
        while bits > 0 {
            a.update(data: (bits & 1) != 0 ? digestB : pw)
            bits >>= 1
        }
        let digestA = Array(a.finalize())

        // Steps 13–15: DP = SHA512(pw repeated pw.count times)
        var dp = SHA512()
        for _ in 0..<pw.count { dp.update(data: pw) }
        let digestDP = Array(dp.finalize())
        var p: [UInt8] = []; p.reserveCapacity(pw.count)
        while p.count + 64 <= pw.count { p.append(contentsOf: digestDP) }
        p.append(contentsOf: digestDP.prefix(pw.count - p.count))

        // Steps 17–19: DS = SHA512(salt repeated 16 + A[0] times)
        var ds = SHA512()
        for _ in 0..<(16 + Int(digestA[0])) { ds.update(data: st) }
        let digestDS = Array(ds.finalize())
        var s: [UInt8] = []; s.reserveCapacity(st.count)
        while s.count + 64 <= st.count { s.append(contentsOf: digestDS) }
        s.append(contentsOf: digestDS.prefix(st.count - s.count))

        // Step 21: 5000 rounds
        var ac = digestA
        for round in 0..<rounds {
            var c = SHA512()
            c.update(data: (round & 1) != 0 ? p : ac)
            if round % 3 != 0 { c.update(data: s) }
            if round % 7 != 0 { c.update(data: p) }
            c.update(data: (round & 1) != 0 ? ac : p)
            ac = Array(c.finalize())
        }

        // Step 22: custom base64 with the spec's byte permutation
        var out = ""
        func encode(_ b2: UInt8, _ b1: UInt8, _ b0: UInt8, chars: Int) {
            var w = (UInt32(b2) << 16) | (UInt32(b1) << 8) | UInt32(b0)
            for _ in 0..<chars { out.append(b64Alphabet[Int(w & 0x3f)]); w >>= 6 }
        }
        let idx: [(Int, Int, Int)] = [
            (0, 21, 42), (22, 43, 1), (44, 2, 23), (3, 24, 45), (25, 46, 4),
            (47, 5, 26), (6, 27, 48), (28, 49, 7), (50, 8, 29), (9, 30, 51),
            (31, 52, 10), (53, 11, 32), (12, 33, 54), (34, 55, 13), (56, 14, 35),
            (15, 36, 57), (37, 58, 16), (59, 17, 38), (18, 39, 60), (40, 61, 19),
            (62, 20, 41),
        ]
        for (i2, i1, i0) in idx { encode(ac[i2], ac[i1], ac[i0], chars: 4) }
        encode(0, 0, ac[63], chars: 2)
        return "$6$\(salt)$\(out)"
    }

    /// 16 random chars from the crypt alphabet.
    public static func generateSalt() -> String {
        String((0..<16).compactMap { _ in b64Alphabet.randomElement() })
    }
}

/// Errors from ``SHA512Crypt``.
public enum SHA512CryptError: Error, Equatable {
    /// Salt was empty or contained `$`/`:`.
    case invalidSalt
}
```
(If `update(data:)` type friction arises with array slices, wrap in `Data(...)` — CryptoKit's `update(data:)` accepts any `DataProtocol`.)

- [ ] **Step 4: Run** `swift test --filter SHA512Crypt` — expect 4 PASS. The reference vector failing means a permutation/rounds bug: re-check `idx` table against spec step 22 before touching the round loop.

- [ ] **Step 5: Commit** `git add Sources/SpooktacularCore/SHA512Crypt.swift Tests/SpooktacularKitTests/SHA512CryptTests.swift && git commit -m "feat(core): SHA-512-crypt for cloud-init password hashes"` (+ trailers).

---

### Task 2: CloudInitSeed — user-data/meta-data generation + cidata ISO

**Files:**
- Create: `Sources/SpooktacularApplication/CloudInitSeed.swift`
- Test: `Tests/SpooktacularKitTests/CloudInitSeedTests.swift`

**Interfaces:**
- Consumes: `SHA512Crypt.hash(password:salt:)`, `SHA512Crypt.generateSalt()` (Task 1); `GuestProvisioningSpec` (exists: fullName/username/password/logsInAutomatically/enablesRemoteLogin).
- Produces:
  - `public struct CloudInitSeed { public init(spec: GuestProvisioningSpec, instanceID: UUID, hostname: String, runScript: String?, authorizedKeys: [String]) throws }` (init hashes the password via SHA512Crypt — plaintext never stored on the struct)
  - `public var userData: String` / `public var metaData: String`
  - `public func writeISO(to isoURL: URL) throws` — stages both files in a temp dir, runs `/usr/bin/hdiutil makehybrid -iso -joliet -default-volume-name cidata -o <iso> <dir>`, throws `CloudInitSeedError.isoBuildFailed(status:stderr:)` on non-zero exit.

- [ ] **Step 1: Write failing tests:**

```swift
import Testing
import Foundation
import SpooktacularCore
@testable import SpooktacularApplication

@Suite("CloudInitSeed")
struct CloudInitSeedTests {
    private func makeSeed(script: String? = nil) throws -> CloudInitSeed {
        try CloudInitSeed(
            spec: GuestProvisioningSpec(fullName: "Admin", username: "admin", password: "hunter2hunter2"),
            instanceID: UUID(uuidString: "D5C8A6DA-DD80-49D4-9FE2-855ADA4AFA1F")!,
            hostname: "dev-box", runScript: script, authorizedKeys: ["ssh-ed25519 AAAA test@host"])
    }
    @Test("user-data carries the account with a $6$ hash, never plaintext")
    func hashNotPlaintext() throws {
        let ud = try makeSeed().userData
        #expect(ud.hasPrefix("#cloud-config"))
        #expect(ud.contains("name: admin"))
        #expect(ud.contains("passwd: $6$"))
        #expect(!ud.contains("hunter2hunter2"))
        #expect(ud.contains("ssh_pwauth: true"))
        #expect(ud.contains("expire: false"))
        #expect(ud.contains("ssh-ed25519 AAAA test@host"))
    }
    @Test("run script rides runcmd via a written file")
    func runcmd() throws {
        let ud = try makeSeed(script: "#!/bin/bash\necho hi\n").userData
        #expect(ud.contains("write_files:"))
        #expect(ud.contains("path: /var/lib/spooktacular/first-boot.sh"))
        #expect(ud.contains("runcmd:"))
        #expect(ud.contains("[bash, /var/lib/spooktacular/first-boot.sh]"))
    }
    @Test("meta-data carries instance id + hostname")
    func metaData() throws {
        let md = try makeSeed().metaData
        #expect(md.contains("instance-id: iid-D5C8A6DA-DD80-49D4-9FE2-855ADA4AFA1F"))
        #expect(md.contains("local-hostname: dev-box"))
    }
    @Test("writeISO produces a cidata ISO9660 image")
    func isoBuild() throws {
        let iso = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-\(UUID().uuidString).iso")
        defer { try? FileManager.default.removeItem(at: iso) }
        try makeSeed().writeISO(to: iso)
        let data = try Data(contentsOf: iso)
        #expect(data.count > 2048)
        // ISO9660 primary volume descriptor: "CD001" at offset 0x8001.
        #expect(data.count > 0x8006 && Array(data[0x8001...0x8005]) == Array("CD001".utf8))
        #expect(String(data: data, encoding: .isoLatin1)?.contains("cidata") == true
            || String(data: data, encoding: .isoLatin1)?.contains("CIDATA") == true)
    }
}
```
(Note: the test file uses one force-unwrap on a constant UUID literal — replace with `try #require(UUID(uuidString: ...))` to honor the no-`!` rule.)

- [ ] **Step 2: Run** `swift test --filter CloudInitSeed` — FAIL (type missing).

- [ ] **Step 3: Implement:**

```swift
import Foundation
import SpooktacularCore

/// A cloud-init NoCloud seed: `user-data` + `meta-data`, packaged as a
/// `cidata`-labeled ISO attached read-only to a Linux guest's first boot.
///
/// This is Linux's counterpart to macOS native provisioning + the
/// injected provisioner daemon: cloud-init (preinstalled in every cloud
/// image) creates the account, enables SSH, and runs the first-boot
/// script **as root** from `runcmd`. The password is embedded only as a
/// SHA-512-crypt hash (`SHA512Crypt`) — the same at-rest posture as
/// `/etc/shadow`; plaintext never touches the host disk.
///
/// NoCloud datasource contract (volume label `cidata`/`CIDATA`, files
/// `user-data` + `meta-data`): verified against cloud-init's NoCloud
/// documentation at implementation time.
public struct CloudInitSeed {

    /// Guest path the first-boot script is written to via `write_files`.
    public static let guestScriptPath = "/var/lib/spooktacular/first-boot.sh"

    public let userData: String
    public let metaData: String

    public init(
        spec: GuestProvisioningSpec,
        instanceID: UUID,
        hostname: String,
        runScript: String?,
        authorizedKeys: [String]
    ) throws {
        let hashed = try SHA512Crypt.hash(
            password: spec.password, salt: SHA512Crypt.generateSalt()
        )
        var ud = """
        #cloud-config
        users:
          - name: \(spec.username)
            gecos: \(spec.fullName)
            groups: [sudo, wheel]
            sudo: ALL=(ALL) NOPASSWD:ALL
            shell: /bin/bash
            lock_passwd: false
            passwd: \(hashed)
        """
        if !authorizedKeys.isEmpty {
            ud += "\n    ssh_authorized_keys:\n"
            ud += authorizedKeys.map { "      - \($0)" }.joined(separator: "\n")
        }
        ud += """

        ssh_pwauth: true
        chpasswd:
          expire: false
        """
        if let runScript {
            // base64 keeps arbitrary script bytes YAML-safe.
            let b64 = Data(runScript.utf8).base64EncodedString()
            ud += """

            write_files:
              - path: \(Self.guestScriptPath)
                permissions: '0700'
                encoding: b64
                content: \(b64)
            runcmd:
              - [bash, \(Self.guestScriptPath)]
            """
        }
        self.userData = ud + "\n"
        self.metaData = """
        instance-id: iid-\(instanceID.uuidString)
        local-hostname: \(hostname)

        """
    }

    /// Builds the `cidata` ISO with `hdiutil makehybrid` (native tool —
    /// no third-party deps). Stages `user-data`/`meta-data` in a private
    /// temp dir, 0700, removed on exit.
    public func writeISO(to isoURL: URL) throws {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("cidata-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        try Data(userData.utf8).write(to: stage.appendingPathComponent("user-data"))
        try Data(metaData.utf8).write(to: stage.appendingPathComponent("meta-data"))
        try? fm.removeItem(at: isoURL)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["makehybrid", "-iso", "-joliet",
                          "-default-volume-name", "cidata",
                          "-o", isoURL.path, stage.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let err = String(
                data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8) ?? ""
            throw CloudInitSeedError.isoBuildFailed(
                status: proc.terminationStatus, stderr: err)
        }
    }
}

/// Errors from ``CloudInitSeed``.
public enum CloudInitSeedError: Error, LocalizedError, Equatable {
    /// `hdiutil makehybrid` exited non-zero.
    case isoBuildFailed(status: Int32, stderr: String)
    public var errorDescription: String? {
        switch self {
        case .isoBuildFailed(let status, let stderr):
            "Building the cloud-init seed ISO failed (hdiutil exit \(status)): \(stderr)"
        }
    }
}
```

- [ ] **Step 4: Run** `swift test --filter CloudInitSeed` — 4 PASS (the ISO test runs real `hdiutil`; it works headless).

- [ ] **Step 5: Commit** `git commit -m "feat(app): cloud-init NoCloud seed generation + cidata ISO"` (+ trailers).

---

### Task 3: LinuxCloudImage — `--from-image` resolution (path, `fedora`, `debian`)

**Files:**
- Create: `Sources/SpooktacularApplication/LinuxCloudImage.swift`
- Test: `Tests/SpooktacularKitTests/LinuxCloudImageTests.swift`

**Interfaces:**
- Produces:
  - `public enum LinuxCloudImage { public static func resolve(_ argument: String, fetch: (URL) async throws -> Data) async throws -> Resolution }`
  - `public enum Resolution: Equatable { case localFile(URL, xzCompressed: Bool); case download(url: URL, suggestedFileName: String, xzCompressed: Bool) }`
  - `public static func parseFedoraReleases(_ json: Data) throws -> URL` — newest aarch64 Cloud raw.xz from https://fedoraproject.org/releases.json
  - `public static func parseDebianIndex(_ html: Data) throws -> URL` — highest `debian-NN-genericcloud-arm64.raw` under `https://cloud.debian.org/images/cloud/<codename>/latest/`
  - `public static func decompressXZ(at src: URL, to dst: URL) throws` — Apple Compression framework, streaming.
- Injection seam: `fetch` closure so tests use fixtures; CLI passes a URLSession-backed closure.

- [ ] **Step 1: Doc-verify the xz claim.** Run `mcp__xcode__DocumentationSearch` for `COMPRESSION_LZMA xz container Compression framework`. Expected per Apple docs: `Compression.lzma` is "the LZMA compression algorithm, in the xz container format". Record the doc URI in the implementation comment. If the docs do NOT say xz container, STOP and switch `decompressXZ` to spawn `/usr/bin/gunzip`-style external tool — do not guess (there is no `/usr/bin/xz` on stock macOS; the fallback is erroring with "install xz or pass an uncompressed image", still shippable).

- [ ] **Step 2: Fetch live fixtures** (also validates the endpoints exist today):

```bash
mkdir -p Tests/SpooktacularKitTests/Fixtures
curl -fsSL https://fedoraproject.org/releases.json -o Tests/SpooktacularKitTests/Fixtures/fedora-releases.json
curl -fsSL https://cloud.debian.org/images/cloud/ -o Tests/SpooktacularKitTests/Fixtures/debian-cloud-index.html
head -c 400 Tests/SpooktacularKitTests/Fixtures/fedora-releases.json
```
Inspect both files; confirm the Fedora JSON objects carry `arch`, `variant`, `link` keys and at least one entry with `"variant": "Cloud"`, `"arch": "aarch64"`, link ending `.raw.xz`; confirm the Debian index lists release-codename directories. **Adjust the parsing code in Step 4 to the observed real shapes** — the shapes below are the expected ones, but the fixture is the truth. Register the fixtures in `Package.swift` test-target resources if not already covered by a wildcard.

- [ ] **Step 3: Write failing tests:**

```swift
import Testing
import Foundation
@testable import SpooktacularApplication

@Suite("LinuxCloudImage")
struct LinuxCloudImageTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
    @Test("fedora releases.json resolves to newest aarch64 Cloud raw.xz")
    func fedora() throws {
        let url = try LinuxCloudImage.parseFedoraReleases(fixture("fedora-releases.json"))
        #expect(url.absoluteString.contains("aarch64"))
        #expect(url.absoluteString.hasSuffix(".raw.xz"))
    }
    @Test("debian index resolves to highest genericcloud-arm64 raw")
    func debian() throws {
        let url = try LinuxCloudImage.parseDebianIndex(fixture("debian-cloud-index.html"))
        #expect(url.absoluteString.contains("genericcloud-arm64"))
        #expect(url.absoluteString.hasSuffix(".raw"))
        #expect(url.absoluteString.contains("/latest/"))
    }
    @Test("local .raw path resolves without fetch")
    func localRaw() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("img-\(UUID()).raw")
        FileManager.default.createFile(atPath: tmp.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = try await LinuxCloudImage.resolve(tmp.path) { _ in Data() }
        #expect(r == .localFile(tmp.standardizedFileURL, xzCompressed: false))
    }
    @Test("local .raw.xz marks xzCompressed")
    func localXZ() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("img-\(UUID()).raw.xz")
        FileManager.default.createFile(atPath: tmp.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = try await LinuxCloudImage.resolve(tmp.path) { _ in Data() }
        #expect(r == .localFile(tmp.standardizedFileURL, xzCompressed: true))
    }
    @Test("qcow2 rejected with conversion hint")
    func qcow2() async {
        await #expect(throws: LinuxCloudImageError.self) {
            _ = try await LinuxCloudImage.resolve("/tmp/foo.qcow2") { _ in Data() }
        }
    }
    @Test("xz round-trip via Compression framework")
    func xz() throws {
        // 64KB of patterned data, compressed with a tiny known-good xz blob
        // is impractical inline — instead round-trip: compress with the
        // framework, decompress with decompressXZ, compare.
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("p-\(UUID()).bin")
        let xz  = src.appendingPathExtension("xz")
        let out = src.appendingPathExtension("out")
        defer { for f in [src, xz, out] { try? FileManager.default.removeItem(at: f) } }
        let payload = Data((0..<65536).map { UInt8($0 % 251) })
        try payload.write(to: src)
        try LinuxCloudImage.compressXZForTesting(at: src, to: xz)
        try LinuxCloudImage.decompressXZ(at: xz, to: out)
        #expect(try Data(contentsOf: out) == payload)
    }
}
```

- [ ] **Step 4: Run to see FAIL, then implement.** Parsing shapes (adjust to fixtures from Step 2):

```swift
import Foundation
import Compression

/// Resolves `--from-image` arguments for Linux cloud images and handles
/// xz decompression. Aliases resolve **at runtime** against the distro's
/// official index — never a hardcoded release:
///  - `fedora` → newest aarch64 Cloud `.raw.xz` in
///    https://fedoraproject.org/releases.json
///  - `debian` → highest `debian-NN-genericcloud-arm64.raw` under
///    https://cloud.debian.org/images/cloud/<codename>/latest/
/// Local paths accept `.raw`, raw `.img`, and `.raw.xz`/`.img.xz`.
/// qcow2 (Ubuntu's cloud format) is rejected with a conversion hint.
public enum LinuxCloudImage {

    public enum Resolution: Equatable {
        case localFile(URL, xzCompressed: Bool)
        case download(url: URL, suggestedFileName: String, xzCompressed: Bool)
    }

    public static func resolve(
        _ argument: String,
        fetch: (URL) async throws -> Data
    ) async throws -> Resolution {
        switch argument.lowercased() {
        case "fedora":
            guard let index = URL(string: "https://fedoraproject.org/releases.json") else {
                throw LinuxCloudImageError.badIndexURL
            }
            let url = try parseFedoraReleases(try await fetch(index))
            return .download(url: url, suggestedFileName: url.lastPathComponent, xzCompressed: true)
        case "debian":
            guard let index = URL(string: "https://cloud.debian.org/images/cloud/") else {
                throw LinuxCloudImageError.badIndexURL
            }
            let url = try parseDebianIndex(try await fetch(index))
            return .download(url: url, suggestedFileName: url.lastPathComponent, xzCompressed: false)
        default:
            let expanded = (argument as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded).standardizedFileURL
            let name = url.lastPathComponent.lowercased()
            if name.hasSuffix(".qcow2") {
                throw LinuxCloudImageError.qcow2Unsupported(url.path)
            }
            guard name.hasSuffix(".raw") || name.hasSuffix(".img")
                || name.hasSuffix(".raw.xz") || name.hasSuffix(".img.xz") else {
                throw LinuxCloudImageError.unsupportedFormat(url.path)
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw LinuxCloudImageError.fileNotFound(url.path)
            }
            return .localFile(url, xzCompressed: name.hasSuffix(".xz"))
        }
    }

    /// releases.json is a flat array of {version, arch, variant, link, ...}.
    public static func parseFedoraReleases(_ json: Data) throws -> URL {
        struct Entry: Decodable {
            let version: String; let arch: String; let variant: String; let link: String
        }
        let entries = try JSONDecoder().decode([Entry].self, from: json)
        let candidates = entries.filter {
            $0.arch == "aarch64" && $0.variant == "Cloud" && $0.link.hasSuffix(".raw.xz")
        }
        let best = candidates.max { (Int($0.version) ?? 0) < (Int($1.version) ?? 0) }
        guard let best, let url = URL(string: best.link) else {
            throw LinuxCloudImageError.indexParseFailed("fedora releases.json")
        }
        return url
    }

    /// Directory index HTML: find codename dirs, take highest debian-NN
    /// genericcloud arm64 raw under <codename>/latest/. Regex the hrefs.
    public static func parseDebianIndex(_ html: Data) throws -> URL {
        guard let text = String(data: html, encoding: .utf8) else {
            throw LinuxCloudImageError.indexParseFailed("debian index (not utf8)")
        }
        // href="bookworm/"  href="trixie/" ...
        let codenames = text.matches(of: /href="([a-z]+)\//).map { String($0.1) }
            .filter { !["daily", "images", "cloud"].contains($0) }
        // Highest release number is discovered via the per-codename latest
        // filename fetched lazily by the caller — but a single-fetch design
        // keeps the seam simple: this parser instead returns the
        // conventional latest URL for the newest codename listed LAST in
        // Debian's index ordering, verified against the fixture.
        guard let newest = codenames.last else {
            throw LinuxCloudImageError.indexParseFailed("debian index (no codenames)")
        }
        guard let url = URL(string:
            "https://cloud.debian.org/images/cloud/\(newest)/latest/") else {
            throw LinuxCloudImageError.indexParseFailed("debian latest URL")
        }
        // NOTE to implementer: the fixture decides whether "last listed ==
        // newest stable" holds and what the raw filename inside latest/ is
        // (debian-NN-genericcloud-arm64.raw). If the index doesn't order
        // that way, parse the NN out of a second fetch of latest/ instead —
        // adjust this function + test to the observed truth, keeping the
        // signature. Return the FULL file URL, not the directory.
        return url
    }

    /// Streaming xz decode via Compression framework.
    /// COMPRESSION_LZMA is the xz container format (doc URI cited per
    /// Task 3 Step 1 verification).
    public static func decompressXZ(at src: URL, to dst: URL) throws {
        try filter(src: src, dst: dst, op: .decompress)
    }
    /// Test-only helper so the round-trip test needs no binary fixture.
    public static func compressXZForTesting(at src: URL, to dst: URL) throws {
        try filter(src: src, dst: dst, op: .compress)
    }

    private static func filter(src: URL, dst: URL, op: FilterOperation) throws {
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let output = try FileHandle(forWritingTo: dst)
        defer { try? output.close() }
        let outFilter = try OutputFilter(op, using: .lzma) { data in
            if let data { output.write(data) }
        }
        while true {
            let chunk = input.readData(ofLength: 1 << 20)
            try outFilter.write(chunk)
            if chunk.isEmpty { break }
        }
        try outFilter.finalize()
    }
}

/// Errors from ``LinuxCloudImage``.
public enum LinuxCloudImageError: Error, LocalizedError, Equatable {
    case badIndexURL
    case indexParseFailed(String)
    case unsupportedFormat(String)
    case qcow2Unsupported(String)
    case fileNotFound(String)
    public var errorDescription: String? {
        switch self {
        case .badIndexURL: "Internal error: malformed distro index URL."
        case .indexParseFailed(let what): "Could not parse \(what) — the distro may have changed its index format."
        case .unsupportedFormat(let p): "Unsupported image format: \(p). Use a raw image (.raw, .img, optionally .xz-compressed)."
        case .qcow2Unsupported(let p): "\(p) is a qcow2 image. Convert it first: qemu-img convert -O raw <src> <dst>.raw (brew install qemu)."
        case .fileNotFound(let p): "Image not found at \(p)."
        }
    }
}
```
`OutputFilter`/`FilterOperation` come from Apple's Compression Swift API (`import Compression`) — doc-verify the exact initializer labels in Step 1's search; adjust to compile.

- [ ] **Step 5: Run** `swift test --filter LinuxCloudImage` — all PASS (parsers running against the real fixtures fetched in Step 2).

- [ ] **Step 6: Commit** `git commit -m "feat(app): --from-image resolution (fedora/debian latest, raw/raw.xz, xz decode)"` (+ trailers).

---

### Task 4: Bundle + config + start lifecycle for the seed

**Files:**
- Modify: `Sources/SpooktacularInfrastructureApple/VirtualMachineBundle.swift` (file-name constants block, ~line 95)
- Modify: `Sources/SpooktacularInfrastructureApple/VirtualMachineConfiguration.swift` (`applyProvisioning`, line ~391)
- Modify: `Sources/spooktacular-cli/Commands/Start.swift` (marker consume block, line ~249)
- Modify: `Sources/Spooktacular/AppState.swift` (`startVM` consume block, ~line 657–730)
- Test: `Tests/SpooktacularKitTests/VMBundleTests.swift` (extend)

**Interfaces:**
- Consumes: `VirtualMachineBundle.writeMetadata(_:to:)`, `metadata.pendingProvisioning: PendingProvisioning?` (existing), `bundle.spec.guestOS` (`.macOS`/`.linux`).
- Produces: `VirtualMachineBundle.seedISOFileName == "seed.iso"`, `bundle.seedISOURL: URL`; config auto-attaches the seed read-only for Linux guests when the file exists; **Linux start** = plain boot (cloud-init works alone) then on success: delete `seed.iso`, clear marker; macOS branch unchanged.

- [ ] **Step 1: Failing test in `VMBundleTests.swift`** (follow that file's existing bundle-fixture pattern for creating a temp bundle):

```swift
@Test("linux bundle exposes seedISOURL and scrubs it via scrubSeed()")
func seedLifecycle() throws {
    let bundle = try makeTempLinuxBundle()   // reuse the file's existing helper; add one if absent
    #expect(bundle.seedISOURL.lastPathComponent == "seed.iso")
    try Data("iso".utf8).write(to: bundle.seedISOURL)
    #expect(FileManager.default.fileExists(atPath: bundle.seedISOURL.path))
    try bundle.scrubSeed()
    #expect(!FileManager.default.fileExists(atPath: bundle.seedISOURL.path))
    try bundle.scrubSeed()   // idempotent
}
```

- [ ] **Step 2: Implement bundle additions** next to `installerISOFileName`:

```swift
/// cloud-init NoCloud seed ISO (`cidata`), present only between a
/// provisioned Linux create and its first successful start.
public static let seedISOFileName = "seed.iso"
```
plus, near the other URL accessors and following their exact style:
```swift
/// Location of the cloud-init seed ISO, when present.
public var seedISOURL: URL { url.appendingPathComponent(Self.seedISOFileName) }

/// Removes the cloud-init seed after the first successful boot —
/// the hash-bearing user-data must not outlive provisioning.
/// Idempotent: missing file is success.
public func scrubSeed() throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: seedISOURL.path) else { return }
    try fm.removeItem(at: seedISOURL)
}
```

- [ ] **Step 3: Config attach** — in `applyProvisioning(from:to:)` replace the `guard bundle.spec.guestOS == .macOS else { return }` early-return with a switch: the macOS arm keeps the existing share code verbatim; the Linux arm:

```swift
case .linux:
    // cloud-init NoCloud seed: attach read-only when present. The
    // guest's cloud-init finds the `cidata` volume on first boot;
    // afterwards `scrubSeed()` removes the file and this attach
    // naturally disappears.
    guard FileManager.default.fileExists(atPath: bundle.seedISOURL.path) else { return }
    let attachment = try VZDiskImageStorageDeviceAttachment(
        url: bundle.seedISOURL, readOnly: true
    )
    configuration.storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
```
(Mirror the exact construction used for `installerISOURL` at ~line 684 — same types, same style.)

- [ ] **Step 4: Start.swift** — the existing marker block (line ~249) is macOS-shaped (Keychain). Gate it: `if bundle.spec.guestOS == .macOS { …existing… } else { … }` where the Linux arm is:

```swift
// Linux: cloud-init already carries everything (account hash +
// script) on the attached seed — boot plainly, then scrub the
// seed and clear the marker so the hash doesn't outlive first
// boot. Cleanup failures must not fail a successful boot.
try await vm.startOrResume()
print(Style.success("✓ First boot with cloud-init provisioning (account '\(marker.username)')."))
do { try bundle.scrubSeed() } catch {
    print(Style.dim("Could not remove seed.iso: \(error.localizedDescription)"))
}
do {
    var meta = bundle.metadata
    meta.pendingProvisioning = nil
    try VirtualMachineBundle.writeMetadata(meta, to: bundleURL)
} catch {
    print(Style.dim("Could not clear pending provisioning: \(error.localizedDescription)"))
}
```

- [ ] **Step 5: AppState.startVM** — in the marker-consume path, branch identically: for `.linux`, skip the Keychain read entirely (no password needed), pass `guestProvisioning: nil` to `startOrResume`, and in the post-success cleanup call `try bundle.scrubSeed()` alongside the existing marker-clear + reload. Follow the exact structure of the existing cleanup `do/catch` there (non-fatal, `Log.vm.warning`).

- [ ] **Step 6:** `swift build && swift test --parallel --skip SpooktacularUITests` — green; `swiftlint --strict --quiet` clean.

- [ ] **Step 7: Commit** `git commit -m "feat(vm): cidata seed attach + scrub lifecycle for Linux first boot"` (+ trailers).

---

### Task 5: Create.swift — provisioned Linux create (`--from-image`)

**Files:**
- Modify: `Sources/spooktacular-cli/Commands/Create.swift` — add `@Option` near the existing ones (~line 176); rework the Linux branch (~line 1030–1188)
- Test: `Tests/SpooktacularKitTests/PendingProvisioningTests.swift` (extend with a marker-for-linux expectation only; the branch itself is covered by live validation in Task 9)

**Interfaces:**
- Consumes: `LinuxCloudImage.resolve/decompressXZ` (Task 3), `CloudInitSeed` (Task 2), `bundle.seedISOURL` (Task 4), existing `EphemeralCredential.generatePassword()`, `GuestProvisioningSpec(...).validated()`, `.pendingMarker`, `VirtualMachineBundle.writeMetadata`.
- Produces: `spook create <name> --os linux --from-image <path|fedora|debian> [--vm-user --vm-password --user-data --openclaw --github-runner ...]` — no root required.

- [ ] **Step 1: Add the option** (exact style of the file's other options):

```swift
@Option(
    name: .customLong("from-image"),
    help: """
        Linux cloud image to boot from: a local raw image (.raw, .img, \
        optionally .xz) or an alias — 'fedora' / 'debian' — resolved at \
        create time to the distro's latest aarch64 cloud image. Enables \
        first-boot provisioning via cloud-init (account, SSH, first-boot \
        script) with no Setup Assistant and no root on the host. \
        Mutually exclusive with --installer-iso.
        """
)
var fromImage: String?
```

- [ ] **Step 2: Rework the Linux branch.** Keep the `--installer-iso` path byte-identical (manual VMs). Add, before it, the `fromImage` path:

1. `let resolution = try await LinuxCloudImage.resolve(fromImage) { url in try await URLSession.shared.data(from: url).0 }` — for `.download`, stream to `~/.spooktacular/cache/images/<suggestedFileName>` (create dir; skip download when cached; print progress like the IPSW path does).
2. Create the bundle exactly as the existing branch does (`VirtualMachineBundle.create` — same spec but `guestToolsInstall: .disabled`).
3. Materialize the disk: xz → `LinuxCloudImage.decompressXZ(at: image, to: bundle.diskImageURL)`; plain raw → `FileManager.copyItem`. Then grow to `--disk`:
```swift
let handle = try FileHandle(forWritingTo: diskURL)
defer { try? handle.close() }
let target = UInt64(disk) * 1_073_741_824
if try handle.seekToEnd() < target { try handle.truncate(atOffset: target) }
```
(cloud-init's growpart expands the root filesystem to fill it on first boot.)
4. Build the provisioning spec exactly as the macOS branch does at ~line 852 (`vmPassword ?? EphemeralCredential.generatePassword()`, `.validated()`, fullName per template), collect the template script (Task 6/7 provides `scriptContent(for: .linux)`; `--user-data` reads the file), gather `authorizedKeys` from `~/.ssh/id_ed25519.pub` / `id_rsa.pub` when readable, then:
```swift
let seed = try CloudInitSeed(
    spec: provisioningSpec, instanceID: bundle.metadata.id,
    hostname: name, runScript: script, authorizedKeys: keys)
try seed.writeISO(to: bundle.seedISOURL)
var meta = bundle.metadata
meta.pendingProvisioning = provisioningSpec.pendingMarker
try VirtualMachineBundle.writeMetadata(meta, to: bundleURL)
```
5. Credentials output: reuse the macOS branch's exact print panel + `--json` `provisioning:` field (lines ~886–948) — factor that output block into a private helper `emitCreateResult(...)` used by both branches rather than duplicating it.
6. Fail-fast validation: `--from-image` + `--installer-iso` together → the file's standard validation error style; `--remote-desktop --os linux` → "Remote Desktop is macOS-only today".

- [ ] **Step 3:** `swift build`; then sanity: `./Spooktacular.app/Contents/MacOS/spook create --help | grep -A3 from-image` after a `./build-app.sh` — help text present.

- [ ] **Step 4:** Full gate (`swift test …`, `swiftlint --strict`) then commit `git commit -m "feat(cli): provisioned Linux create via cloud images + cidata seed"` (+ trailers).

---

### Task 6: OpenClawTemplate — root-context macOS rewrite + OS parameter

**Files:**
- Modify: `Sources/SpooktacularApplication/OpenClawTemplate.swift`
- Test: `Tests/SpooktacularKitTests/OpenClawTemplateTests.swift` (create; mirror whatever template test exists for GitHubRunnerTemplate if present, else new)

**Interfaces:**
- Consumes: `GuestOS` (SpooktacularCore), the provisioned account username (parameter).
- Produces: `OpenClawTemplate.scriptContent(for os: GuestOS, username: String) -> String` and `generate(for:username:) throws -> URL`. Existing callers (Create.swift, AppState) updated to pass `(.macOS, resolved --vm-user)` — compile errors surface every call site; fix them all.

- [ ] **Step 1: Failing tests:**

```swift
import Testing
import SpooktacularCore
@testable import SpooktacularApplication

@Suite("OpenClawTemplate")
struct OpenClawTemplateTests {
    @Test("macOS script is root-context safe: no Homebrew, drops privileges for user steps")
    func macOSRootSafe() {
        let s = OpenClawTemplate.scriptContent(for: .macOS, username: "admin")
        #expect(!s.contains("brew"))
        #expect(!s.contains("Homebrew"))
        #expect(s.contains("installer -pkg"))
        #expect(s.contains("nodejs.org/dist/index.json"))   // latest 24.x resolved at runtime
        #expect(s.contains("sudo -u \"$OPENCLAW_USER\""))
        #expect(s.contains("OPENCLAW_USER=\"admin\""))
        #expect(s.contains("launchctl"))
    }
    @Test("linux script installs official arm64 tarball + systemd unit")
    func linuxShape() {
        let s = OpenClawTemplate.scriptContent(for: .linux, username: "admin")
        #expect(s.contains("linux-arm64.tar.xz"))
        #expect(s.contains("/usr/local"))
        #expect(s.contains("systemctl enable"))
        #expect(s.contains("User=admin"))
        #expect(!s.contains("brew"))
    }
}
```

- [ ] **Step 2: Implement.** Replace the body. macOS script (root context — the provisioner daemon runs this as root; copy `GitHubRunnerTemplate`'s wait-and-`sudo -u` pattern, lines 188–237 of that file, for anything per-user):

```bash
#!/bin/bash
set -euo pipefail
OPENCLAW_USER="\(username)"

# Wait for the provisioned account (created by macOS native
# provisioning during this same first boot) to exist.
for _ in $(seq 1 60); do id "$OPENCLAW_USER" >/dev/null 2>&1 && break; sleep 2; done

# Node 24: newest 24.x from the official index (never hardcoded),
# installed via the root-native pkg — Homebrew refuses root.
NODE_V=$(curl -fsSL https://nodejs.org/dist/index.json \
  | grep -o '"v24[^"]*"' | head -1 | tr -d '"')
curl -fsSL "https://nodejs.org/dist/${NODE_V}/node-${NODE_V}.pkg" -o /tmp/node.pkg
installer -pkg /tmp/node.pkg -target /
rm -f /tmp/node.pkg
export PATH="/usr/local/bin:$PATH"

npm install -g openclaw@latest

# Gateway runs as the provisioned user via launchd (UserName key),
# not as root and not as a child of this provisioner script.
sudo -u "$OPENCLAW_USER" /usr/local/bin/openclaw onboard --no-daemon || true
cat > /Library/LaunchDaemons/com.spookylabs.openclaw.gateway.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.spookylabs.openclaw.gateway</string>
  <key>UserName</key><string>\(username)</string>
  <key>ProgramArguments</key><array>
    <string>/usr/local/bin/openclaw</string><string>gateway</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
PLIST
launchctl load -w /Library/LaunchDaemons/com.spookylabs.openclaw.gateway.plist
echo "OpenClaw installed; gateway running as ${OPENCLAW_USER} on port 18789"
```

Linux script (cloud-init runs it as root):

```bash
#!/bin/bash
set -euo pipefail
OPENCLAW_USER="\(username)"

NODE_V=$(curl -fsSL https://nodejs.org/dist/index.json \
  | grep -o '"v24[^"]*"' | head -1 | tr -d '"')
curl -fsSL "https://nodejs.org/dist/${NODE_V}/node-${NODE_V}-linux-arm64.tar.xz" -o /tmp/node.tar.xz
tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1
rm -f /tmp/node.tar.xz

npm install -g openclaw@latest

sudo -u "$OPENCLAW_USER" /usr/local/bin/openclaw onboard --no-daemon || true
cat > /etc/systemd/system/openclaw-gateway.service <<UNIT
[Unit]
Description=OpenClaw gateway
After=network-online.target
[Service]
User=\(username)
ExecStart=/usr/local/bin/openclaw gateway
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now openclaw-gateway.service
echo "OpenClaw installed; gateway running as ${OPENCLAW_USER} on port 18789"
```

Verify `openclaw onboard`'s actual flags before shipping (`npm view openclaw` / its README via WebFetch); if `--no-daemon` doesn't exist, use the closest documented "configure without installing its own daemon" form, or omit onboarding and document that the gateway unit supersedes `--install-daemon`. Fix call sites: `grep -rn "OpenClawTemplate" Sources/` and update each to the new signature.

- [ ] **Step 3:** `swift test --filter OpenClawTemplate` PASS; full gate; commit `git commit -m "fix(app): OpenClaw template runs in root first-boot context; adds Linux variant"` (+ trailers).

---

### Task 7: GitHub runner on Linux + template plumbing

**Files:**
- Modify: `Sources/SpooktacularApplication/GitHubRunnerTemplate.swift` (add `scriptContent(for: .linux, ...)` beside the existing macOS content; existing signature `scriptContent(...)` becomes the `.macOS` case — keep its output byte-identical, the macOS runner flow is out of scope)
- Modify: `Sources/spooktacular-cli/Commands/Create.swift` (allow `--github-runner --os linux --from-image`, reusing the existing token minting + the Task 5 seed path with this script)
- Test: `Tests/SpooktacularKitTests/GitHubRunnerTemplateLinuxTests.swift`

**Interfaces:**
- Consumes: existing token minting (`GitHubRunnerService.issueRegistrationToken` path used by the macOS flow — find it via `grep -n "issueRegistrationToken" Sources/`), `CloudInitSeed` delivery from Task 5.
- Produces: `GitHubRunnerTemplate.scriptContent(for os: GuestOS, repositoryURL: String, registrationToken: String, ephemeral: Bool, runnerName: String?) -> String`.

- [ ] **Step 1: Failing test:**

```swift
import Testing
import SpooktacularCore
@testable import SpooktacularApplication

@Suite("GitHubRunnerTemplate (Linux)")
struct GitHubRunnerTemplateLinuxTests {
    @Test("linux runner script: latest arm64 tarball, dedicated user, systemd, token embedded")
    func shape() {
        let s = GitHubRunnerTemplate.scriptContent(
            for: .linux, repositoryURL: "https://github.com/o/r",
            registrationToken: "REGTOK", ephemeral: true, runnerName: "e2e")
        #expect(s.contains("useradd"))
        #expect(s.contains("actions/runner/releases/latest"))   // resolved at runtime
        #expect(s.contains("linux-arm64"))
        #expect(s.contains("REGTOK"))
        #expect(s.contains("--ephemeral"))
        #expect(s.contains("systemctl"))
        #expect(s.contains("User=runner"))
        #expect(!s.contains("launchctl"))
    }
    @Test("macOS content is untouched by the OS split")
    func macOSStable() {
        let s = GitHubRunnerTemplate.scriptContent(
            for: .macOS, repositoryURL: "https://github.com/o/r",
            registrationToken: "T", ephemeral: false, runnerName: nil)
        #expect(s.contains("launchctl"))
        #expect(s.contains("sudo -u"))
    }
}
```

- [ ] **Step 2: Implement the Linux script** (root context via cloud-init; mirrors the macOS design decisions — dedicated user, `config.sh` not as root, service manager owns the process):

```bash
#!/bin/bash
set -euo pipefail
RUNNER_USER="runner"
RUNNER_DIR="/home/${RUNNER_USER}/actions-runner"

id "$RUNNER_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$RUNNER_USER"
mkdir -p "$RUNNER_DIR"

# Latest runner release resolved at runtime from GitHub's API.
TAG=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
  | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*"v\{0,1\}\([^"]*\)"$/\1/')
curl -fsSL -o /tmp/runner.tar.gz \
  "https://github.com/actions/runner/releases/download/v${TAG}/actions-runner-linux-arm64-${TAG}.tar.gz"
tar -xzf /tmp/runner.tar.gz -C "$RUNNER_DIR"
rm -f /tmp/runner.tar.gz
chown -R "$RUNNER_USER":"$RUNNER_USER" "$RUNNER_DIR"

# Runner dependencies (distro-agnostic helper ships with the runner).
"$RUNNER_DIR"/bin/installdependencies.sh || true

sudo -u "$RUNNER_USER" bash -c "cd '$RUNNER_DIR' && ./config.sh \(configLine)"

cat > /etc/systemd/system/actions-runner.service <<UNIT
[Unit]
Description=GitHub Actions runner
After=network-online.target
[Service]
User=${RUNNER_USER}
WorkingDirectory=${RUNNER_DIR}
ExecStart=${RUNNER_DIR}/run.sh
Restart=\(ephemeral ? "no" : "always")
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now actions-runner.service
```
`\(configLine)` is built exactly like the macOS variant's (`--url … --token … --unattended` + `--ephemeral`/`--name` when set) — read the existing builder and reuse it verbatim (shared private helper, not a copy).

- [ ] **Step 3: Wire Create.swift:** `--github-runner --os linux` requires `--from-image`; mints the registration token via the same call the macOS flow makes (grep from Interfaces), passes this script as the seed's `runScript`. Runner Linux VMs keep `--vm-user` for the *login* account; the runner itself uses its own `runner` user inside the script (matching macOS).

- [ ] **Step 4:** Tests + full gate + commit `git commit -m "feat(runner): GitHub Actions runner template for Linux guests"` (+ trailers).

---

### Task 8: GUI — Linux provisioning section

**Files:**
- Modify: `Sources/Spooktacular/CreateVMSheet.swift` (the `if guestOS == .macOS { Section { provisioningControls … } }` gate at ~line 374; template labels)
- Modify: `Sources/Spooktacular/AppState.swift` (the Linux create flow — find `runLinuxCreate`/equivalent via `grep -n "guestOS: .linux" Sources/Spooktacular/AppState.swift` — add the same resolve→copy→grow→seed→marker pipeline as Task 5, reusing `LinuxCloudImage` + `CloudInitSeed`; surface generated credentials via the existing info-banner/notification pattern used elsewhere in the file)
- Test: build + existing UI-test compile check (`swift build --build-system native --target SpooktacularUITests`)

**Interfaces:**
- Consumes: everything from Tasks 2–5, 6–7.
- Produces: the Provisioning section renders for Linux guests with OpenClaw / GitHub Runner / Custom Script (Remote Desktop shown but disabled with help text "macOS guests only"); GUI Linux create emits seed + marker, rootless.

- [ ] **Step 1:** Remove the `guestOS == .macOS` wrap so the Section always renders; inside `provisioningControls`, when `guestOS == .linux`, exclude `.remoteDesktop` from the offered cases (filtered `ForEach` over `ProvisioningTemplate.allCases`) and add a `.help("Remote Desktop provisioning is macOS-only today.")` note in the footer.
- [ ] **Step 2:** GUI needs an image source for Linux: add a "Cloud Image" file/alias field to the Linux variant of the sheet (mirror the existing IPSW picker row pattern; free-text accepts `fedora` / `debian` / a path) feeding the AppState pipeline.
- [ ] **Step 3:** `./build-app.sh`, open the app, create sheet → Linux: Provisioning section present, templates listed, remote-desktop absent/disabled. (Greyed-picker bug may still grey items — out of scope here; do not chase it in this task.)
- [ ] **Step 4:** Full gate + commit `git commit -m "feat(gui): Linux provisioning section + cloud-image create pipeline"` (+ trailers).

---

### Task 9: Docs + live validation

**Files:**
- Modify: `README.md` (Linux section + flags; test counts synced to actual), `Sources/SpooktacularKit/Documentation.docc/RemoteDesktop.md` (cross-reference), Create: `Sources/SpooktacularKit/Documentation.docc/LinuxProvisioning.md`
- Create: `scripts/validate-linux-provisioning.sh` (the live smoke, runnable by hand)

**Interfaces:** none new — documents Tasks 1–8.

- [ ] **Step 1: DocC page** `LinuxProvisioning.md`: the table from the spec (per-OS initial-script system), the `--from-image` aliases + runtime-latest policy, the hash-only-at-rest + seed-scrub lifecycle, the root story (Linux never needs it; macOS templates do, `sudo` hint), runner-on-Linux example:
```
spook create linux-runner --os linux --from-image fedora \
  --github-runner --github-repo org/repo --github-token-keychain e2e
spook start linux-runner
```
- [ ] **Step 2: README** — Linux quick start (fedora alias, openclaw example), truthful claims only; run whatever README-claims validator exists (`grep -rn "readme" fastlane/Fastfile` to find the lane) and sync counts.
- [ ] **Step 3: `validate-linux-provisioning.sh`** — creates `lx-smoke` with `--from-image fedora --openclaw --vm-user admin`, starts it, polls `spook ip` then `nc -z <ip> 22` (SSH up = account exists) and `nc -z <ip> 18789` (gateway up = openclaw installed), prints PASS/FAIL per check, `spook stop` at the end; header comment: "rootless — run as your normal user".
- [ ] **Step 4:** Run the script live (rootless, image download ~600 MB + boot ≈ minutes). PASS required on SSH; gateway check may legitimately lag npm install — poll up to 10 min. Investigate any FAIL before committing (systematic-debugging, not retry-until-green).
- [ ] **Step 5:** Separately validate the macOS OpenClaw fix needs user sudo — hand the user the exact `sudo spook create oc-smoke --openclaw --from-ipsw <cached>` + `sudo spook start oc-smoke` commands and verify `launchctl print system/com.spookylabs.openclaw.gateway` + port 18789 in-guest when they run it.
- [ ] **Step 6:** Full gate + commit `git commit -m "docs(provisioning): Linux cloud-init guide + live validation script"` (+ trailers).

---

### Task 10: SMAppService privileged helper (GUI macOS disk-inject)

**Design (doc-verified 2026-07-22):** `SMAppService.daemon(plistName:)` with the
plist + helper executable inside the signed app bundle; admin approves once in
System Settings (`.requiresApproval` → `openSystemSettingsLoginItems()`), then
the root daemon bootstraps on every boot. App ↔ helper over `NSXPCConnection`
(mach service, `.privileged`), **both sides pinned** with
`setCodeSigningRequirement` / `setConnectionCodeSigningRequirement` derived at
runtime from the app's own team identifier (`SecCodeCopySigningInformation`) —
never hardcoded, never PID-trust. Helper: two verbs only
(`installProvisionerDaemon(vmBundlePath:)`, `installGuestTools(vmBundlePath:)`),
asset paths derived from the helper's own `Bundle.main` so clients cannot
retarget the root process; `dispatchPrecondition` root assert per DTS guidance.
Script injection stays in-app (provision share is a host-side rootless write).

**Files:** `Sources/SpooktacularInfrastructureApple/HelperInterface.swift`
(protocol + mach name + requirement builder), `Sources/spooktacular-helper/main.swift`
(new executable target), `Resources/com.spooktacular.app.helper.plist`,
`Sources/Spooktacular/PrivilegedHelper.swift` (SMAppService + XPC client),
`build-app.sh` assembly/signing, sheet approval row. Tests: requirement-string
builder against the live test-host signature; plist key assertions.

**Verify:** build + lint + suite green; `status` reports `.requiresApproval`
after `register()`; full approve-and-inject e2e requires the user's one-time
System Settings approval (hand-off step).

## Follow-ups explicitly out of this plan
1. **Greyed provisioning picker** — live systematic-debugging session against the running GUI (unknown root cause; blocks nothing above on the CLI path).
2. Ubuntu qcow2; Remote Desktop on Linux; MFA-under-root for `spook delete`.
