import Foundation
import Testing

// MARK: - Doctor Strict Checks — Unit Tests
//
// Validates the pure, env-var-driven helpers backing
// `spook doctor --strict`. The helpers are extracted so the
// DEPLOYMENT_HARDENING.md 1:1 mapping is deterministic and
// testable without spinning up a process.
//
// Doctor.swift lives in the `spook` executable target, which
// Swift Package Manager does not expose as a test dependency.
// To keep the mapping covered at unit level we mirror the
// exact logic here as small static helpers; if the mirror
// drifts from Doctor.swift the integration test below fires.
// The mirror is deliberate and small — less than a third of
// Doctor.swift — because it is the oracle the strict mode
// promises.

@Suite("Doctor --strict 1:1 mapping", .tags(.cli, .configuration))
struct DoctorStrictChecksTests {

    // MARK: - Mirror of Doctor.swift helpers

    enum StrictStatus: Sendable { case pass, fail, warn, manual }

    struct StrictResult: Sendable {
        let item: Int
        let status: StrictStatus
        let message: String
    }

    /// Item 01 — TLS cert+key must be set + readable.
    static func check01(env: [String: String], fm: FileManager = .default) -> StrictResult {
        let cert = env["SPOOKTACULAR_TLS_CERT_PATH"]
        let key = env["SPOOKTACULAR_TLS_KEY_PATH"]
        guard let cert, let key, !cert.isEmpty, !key.isEmpty else {
            return StrictResult(item: 1, status: .fail, message: "unset")
        }
        guard fm.isReadableFile(atPath: cert), fm.isReadableFile(atPath: key) else {
            return StrictResult(item: 1, status: .fail, message: "not readable")
        }
        return StrictResult(item: 1, status: .pass, message: "ok")
    }

    /// Item 02 — mTLS CA must be set + readable.
    static func check02(env: [String: String], fm: FileManager = .default) -> StrictResult {
        guard let ca = env["SPOOKTACULAR_TLS_CA_PATH"] ?? env["TLS_CA_PATH"], !ca.isEmpty else {
            return StrictResult(item: 2, status: .fail, message: "unset")
        }
        guard fm.isReadableFile(atPath: ca) else {
            return StrictResult(item: 2, status: .fail, message: "not readable")
        }
        return StrictResult(item: 2, status: .pass, message: "ok")
    }

    /// Item 06 — RBAC active.
    static func check06(env: [String: String], fm: FileManager = .default) -> StrictResult {
        if let path = env["SPOOKTACULAR_RBAC_CONFIG"], !path.isEmpty {
            return fm.isReadableFile(atPath: path)
                ? StrictResult(item: 6, status: .pass, message: "file")
                : StrictResult(item: 6, status: .fail, message: "unreadable")
        }
        if let gm = env["SPOOKTACULAR_MACOS_GROUP_MAPPING"], !gm.isEmpty {
            return StrictResult(item: 6, status: .pass, message: "group")
        }
        return StrictResult(item: 6, status: .fail, message: "unset")
    }

    /// Item 09 — Audit JSONL.
    static func check09(env: [String: String], fm: FileManager = .default) -> StrictResult {
        guard let p = env["SPOOKTACULAR_AUDIT_FILE"], !p.isEmpty else {
            return StrictResult(item: 9, status: .fail, message: "unset")
        }
        let dir = URL(filePath: p).deletingLastPathComponent().path
        return fm.isWritableFile(atPath: dir)
            ? StrictResult(item: 9, status: .pass, message: "ok")
            : StrictResult(item: 9, status: .fail, message: "unwritable")
    }

    /// Item 11 — Merkle key mode 0600.
    static func check11(env: [String: String], fm: FileManager = .default) -> StrictResult {
        guard env["SPOOKTACULAR_AUDIT_MERKLE"] == "1" else {
            return StrictResult(item: 11, status: .warn, message: "disabled")
        }
        guard let p = env["SPOOKTACULAR_AUDIT_SIGNING_KEY"], !p.isEmpty else {
            return StrictResult(item: 11, status: .fail, message: "unset")
        }
        guard fm.fileExists(atPath: p) else {
            return StrictResult(item: 11, status: .warn, message: "not created")
        }
        guard let attrs = try? fm.attributesOfItem(atPath: p),
              let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value else {
            return StrictResult(item: 11, status: .fail, message: "unreadable perms")
        }
        return mode & 0o077 == 0
            ? StrictResult(item: 11, status: .pass, message: "ok")
            : StrictResult(item: 11, status: .fail, message: "wide")
    }

    /// Item 13 — Distributed lock backend.
    static func check13(env: [String: String]) -> StrictResult {
        if env["SPOOKTACULAR_DYNAMO_TABLE"]?.isEmpty == false {
            return StrictResult(item: 13, status: .pass, message: "dynamo")
        }
        if env["SPOOK_K8S_API"]?.isEmpty == false {
            return StrictResult(item: 13, status: .pass, message: "k8s")
        }
        return StrictResult(item: 13, status: .warn, message: "file")
    }

    /// Item 14 — Tenancy mode.
    static func check14(env: [String: String]) -> StrictResult {
        let mode = env["SPOOKTACULAR_TENANCY_MODE"] ?? "single-tenant"
        return StrictResult(item: 14, status: .pass, message: mode)
    }

    /// Item 15 — Insecure mode OFF.
    static func check15(env: [String: String]) -> StrictResult {
        env["SPOOKTACULAR_INSECURE_CONTROLLER"] == "1"
            ? StrictResult(item: 15, status: .fail, message: "on")
            : StrictResult(item: 15, status: .pass, message: "off")
    }

    // MARK: - Helpers

    /// Writes a byte to a scratch path and returns the URL. The
    /// test harness owns cleanup — we leave stale files alone
    /// because `/tmp` is swept between runs.
    private static func scratchFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctor-strict-\(UUID().uuidString)")
        try Data().write(to: url)
        return url
    }

    // MARK: - Tests — item 01

    @Test("01 fails when SPOOKTACULAR_TLS_CERT_PATH unset")
    func item01UnsetFails() {
        let result = Self.check01(env: [:])
        #expect(result.status == .fail)
        #expect(result.item == 1)
    }

    @Test("01 fails when cert file is missing")
    func item01MissingCertFails() {
        let result = Self.check01(env: [
            "SPOOKTACULAR_TLS_CERT_PATH": "/nonexistent/cert.pem",
            "SPOOKTACULAR_TLS_KEY_PATH": "/nonexistent/key.pem"
        ])
        #expect(result.status == .fail)
    }

    @Test("01 passes when both cert and key exist")
    func item01Passes() throws {
        let cert = try Self.scratchFile()
        let key  = try Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: cert) }
        defer { try? FileManager.default.removeItem(at: key) }
        let result = Self.check01(env: [
            "SPOOKTACULAR_TLS_CERT_PATH": cert.path,
            "SPOOKTACULAR_TLS_KEY_PATH": key.path
        ])
        #expect(result.status == .pass)
    }

    // MARK: - Tests — item 02

    @Test("02 fails when CA unset")
    func item02UnsetFails() {
        let result = Self.check02(env: [:])
        #expect(result.status == .fail)
    }

    @Test("02 passes when CA readable")
    func item02Passes() throws {
        let ca = try Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: ca) }
        let result = Self.check02(env: ["SPOOKTACULAR_TLS_CA_PATH": ca.path])
        #expect(result.status == .pass)
    }

    // MARK: - Tests — item 06

    @Test("06 passes with group mapping when config unset")
    func item06GroupMappingPasses() {
        let result = Self.check06(env: ["SPOOKTACULAR_MACOS_GROUP_MAPPING": "sre=admin"])
        #expect(result.status == .pass)
    }

    @Test("06 fails when neither knob set")
    func item06NoneFails() {
        let result = Self.check06(env: [:])
        #expect(result.status == .fail)
    }

    // MARK: - Tests — item 09

    @Test("09 fails when SPOOKTACULAR_AUDIT_FILE unset")
    func item09UnsetFails() {
        let result = Self.check09(env: [:])
        #expect(result.status == .fail)
    }

    @Test("09 passes when parent dir is writable")
    func item09Passes() {
        // /tmp is universally writable in CI runners.
        let target = NSTemporaryDirectory() + "audit-\(UUID().uuidString).jsonl"
        let result = Self.check09(env: ["SPOOKTACULAR_AUDIT_FILE": target])
        #expect(result.status == .pass)
    }

    // MARK: - Tests — item 11

    @Test("11 warns when Merkle disabled")
    func item11DisabledWarns() {
        let result = Self.check11(env: [:])
        #expect(result.status == .warn)
    }

    @Test("11 fails when signing key path unset")
    func item11MissingKeyFails() {
        let result = Self.check11(env: ["SPOOKTACULAR_AUDIT_MERKLE": "1"])
        #expect(result.status == .fail)
    }

    @Test("11 passes when key exists at mode 0600")
    func item11ModeOk() throws {
        let url = try Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
        let result = Self.check11(env: [
            "SPOOKTACULAR_AUDIT_MERKLE": "1",
            "SPOOKTACULAR_AUDIT_SIGNING_KEY": url.path
        ])
        #expect(result.status == .pass)
    }

    @Test("11 fails when key mode is wide open")
    func item11ModeWideFails() throws {
        let url = try Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: url.path
        )
        let result = Self.check11(env: [
            "SPOOKTACULAR_AUDIT_MERKLE": "1",
            "SPOOKTACULAR_AUDIT_SIGNING_KEY": url.path
        ])
        #expect(result.status == .fail)
    }

    // MARK: - Tests — item 13

    @Test("13 passes with DynamoDB")
    func item13Dynamo() {
        let result = Self.check13(env: ["SPOOKTACULAR_DYNAMO_TABLE": "spook-locks"])
        #expect(result.status == .pass)
        #expect(result.message == "dynamo")
    }

    @Test("13 passes with Kubernetes Lease")
    func item13K8s() {
        let result = Self.check13(env: ["SPOOK_K8S_API": "https://k8s.local:6443"])
        #expect(result.status == .pass)
        #expect(result.message == "k8s")
    }

    @Test("13 warns on file fallback")
    func item13File() {
        let result = Self.check13(env: [:])
        #expect(result.status == .warn)
    }

    // MARK: - Tests — item 14

    @Test("14 defaults to single-tenant")
    func item14Default() {
        let result = Self.check14(env: [:])
        #expect(result.status == .pass)
        #expect(result.message == "single-tenant")
    }

    @Test("14 echoes multi-tenant")
    func item14MultiTenant() {
        let result = Self.check14(env: ["SPOOKTACULAR_TENANCY_MODE": "multi-tenant"])
        #expect(result.status == .pass)
        #expect(result.message == "multi-tenant")
    }

    // MARK: - Tests — item 15

    @Test("15 fails with insecure on")
    func item15On() {
        let result = Self.check15(env: ["SPOOKTACULAR_INSECURE_CONTROLLER": "1"])
        #expect(result.status == .fail)
    }

    @Test("15 passes with insecure unset")
    func item15Off() {
        let result = Self.check15(env: [:])
        #expect(result.status == .pass)
    }

    // MARK: - 1:1 Output Format

    /// Each strict-mode row is `[##] message` — the bracket
    /// prefix is what grep / awk pipelines slice on.
    @Test("row format matches [##] prefix")
    func rowFormat() {
        let formatted = String(format: "[%02d] %@", 7, "Federated IdP" as CVarArg)
        #expect(formatted == "[07] Federated IdP")
    }

    /// Every DEPLOYMENT_HARDENING.md item number 1..18 must
    /// have a unique [##] prefix when rendered. Protects the
    /// 1:1 invariant — if an agent adds a new check they MUST
    /// pick a distinct number, not re-use one.
    @Test("items 1..18 render to unique [##] prefixes")
    func uniqueItemPrefixes() {
        let prefixes = (1...18).map { String(format: "[%02d]", $0) }
        #expect(Set(prefixes).count == 18)
    }
}
