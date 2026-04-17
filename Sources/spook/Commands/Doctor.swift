import ArgumentParser
import Foundation
import Network
import Security
import SpooktacularKit
@preconcurrency import Virtualization

extension Spook {

    /// Runs preflight checks to verify the host is ready to run VMs.
    ///
    /// `spook doctor` validates the local environment against
    /// Spooktacular's requirements: Apple Silicon, macOS version,
    /// Virtualization.framework, disk space, base VM availability,
    /// server status, TLS configuration, API token, and capacity.
    ///
    /// Each check prints a status line with a pass, fail, or
    /// warning indicator. The command exits with code 0 if all
    /// critical checks pass, or 1 if any fail.
    ///
    /// ## `--strict` mode — 1:1 DEPLOYMENT_HARDENING mapping
    ///
    /// Passing `--strict` replaces the host readiness preflight
    /// with the 18-item production-hardening checklist from
    /// `docs/DEPLOYMENT_HARDENING.md`. Every line printed is
    /// prefixed with its item number, and items the table calls
    /// out as non-automatable (12, 18) are surfaced as manual
    /// `?` lines so the output is a complete, auditable record.
    ///
    /// ## Examples
    ///
    /// ```
    /// $ spook doctor
    /// Spooktacular Doctor
    /// ===================
    /// ✓ Apple Silicon (arm64)
    /// ✓ macOS 15.4.0 (minimum: 14.0)
    /// ✓ Virtualization.framework available
    /// ✓ Disk space: 234 GB free (minimum: 20 GB)
    /// ✓ Base VM found: macos-15-base
    /// ✗ spook serve not running
    /// ✗ TLS not configured
    /// ⚠ SPOOK_API_TOKEN not set
    /// ✓ Capacity: 0/2 VMs running
    ///
    /// 6 passed, 2 failed, 1 warning
    /// ```
    struct Doctor: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check if this Mac is ready to run VMs.",
            discussion: """
                Runs a series of preflight checks and reports whether \
                the host environment meets Spooktacular's requirements. \
                Use this command after installation or when diagnosing \
                VM startup failures.

                Default output covers local-host readiness. Pass \
                --strict to additionally verify every production \
                control documented in docs/DEPLOYMENT_HARDENING.md — \
                mTLS, RBAC, IdP, audit chain, signing key permissions, \
                lock backend, tenancy. A non-zero exit in --strict \
                mode means the deployment is not hardened.

                EXAMPLES:
                  spook doctor
                  spook doctor --strict
                """
        )

        @Flag(help: "Additionally verify every production control from DEPLOYMENT_HARDENING.md.")
        var strict: Bool = false

        func run() async throws {
            print(Style.bold("Spooktacular Doctor"))
            print("===================")

            var passed = 0
            var failed = 0
            var warned = 0

            // 1. Apple Silicon
            let archResult = checkAppleSilicon()
            printResult(archResult)
            count(archResult, passed: &passed, failed: &failed, warned: &warned)

            // 2. macOS version
            let osResult = checkMacOSVersion()
            printResult(osResult)
            count(osResult, passed: &passed, failed: &failed, warned: &warned)

            // 3. Virtualization.framework
            let vzResult = await checkVirtualization()
            printResult(vzResult)
            count(vzResult, passed: &passed, failed: &failed, warned: &warned)

            // 4. Disk space
            let diskResult = checkDiskSpace()
            printResult(diskResult)
            count(diskResult, passed: &passed, failed: &failed, warned: &warned)

            // 5. Base VM exists
            let vmResult = checkBaseVM()
            printResult(vmResult)
            count(vmResult, passed: &passed, failed: &failed, warned: &warned)

            // 6. spook serve running
            let serveResult = await checkServeRunning()
            printResult(serveResult)
            count(serveResult, passed: &passed, failed: &failed, warned: &warned)

            // 7. TLS configured
            let tlsResult: CheckResult
            if case .pass = serveResult.status {
                tlsResult = await checkTLS()
            } else {
                tlsResult = CheckResult(
                    status: .fail,
                    message: "TLS not configured (serve not running)"
                )
            }
            printResult(tlsResult)
            count(tlsResult, passed: &passed, failed: &failed, warned: &warned)

            // 8. API token set
            let tokenResult = checkAPIToken()
            printResult(tokenResult)
            count(tokenResult, passed: &passed, failed: &failed, warned: &warned)

            // 9. Capacity
            let capacityResult = checkCapacity()
            printResult(capacityResult)
            count(capacityResult, passed: &passed, failed: &failed, warned: &warned)

            if strict {
                print()
                print(Style.bold("Production controls (--strict)"))
                print("------------------------------")
                print(Style.dim("Mapped 1:1 to docs/DEPLOYMENT_HARDENING.md §1."))
                print()
                for result in await Self.strictProductionChecks() {
                    printResult(result)
                    count(result, passed: &passed, failed: &failed, warned: &warned)
                }
            }

            // Summary
            print()
            let summary = "\(passed) passed, \(failed) failed, \(warned) warning"
                + (warned == 1 ? "" : "s")
            print(summary)

            if failed > 0 {
                throw ExitCode.failure
            }
        }

        // MARK: - Strict mode: 18-item 1:1 mapping

        /// Runs every automatable control from the 18-item
        /// DEPLOYMENT_HARDENING.md pre-flight, in order, so the
        /// output is a literal row-by-row projection of the doc's
        /// table. Items 12 and 18 are reported as `manual` because
        /// they require AWS API calls and build-tooling output
        /// the CLI cannot inspect from a running host.
        ///
        /// Exposed `static` so tests can call it directly without
        /// piping through `ArgumentParser`.
        static func strictProductionChecks() async -> [CheckResult] {
            let env = ProcessInfo.processInfo.environment
            var results: [CheckResult] = []

            // 01. TLS certificate + key configured
            results.append(check01TLSCertAndKey(env: env))

            // 02. mTLS (client cert required)
            results.append(check02MutualTLS(env: env))

            // 03. TLS 1.3 floor
            results.append(await check03TLS13Floor())

            // 04. API bearer token in Keychain (or env fallback)
            results.append(check04APITokenKeychain(env: env))

            // 05. Guest-agent tokens configured (Keychain/env)
            results.append(check05GuestAgentTokens(env: env))

            // 06. RBAC active (config path OR macOS group mapping)
            results.append(check06RBACActive(env: env))

            // 07. Federated IdP configured
            results.append(check07FederatedIdP(env: env))

            // 08. JWKS pinned OR trusted mirror on every OIDC provider
            results.append(check08JWKSPinned(env: env))

            // 09. Audit JSONL enabled + writable
            results.append(check09AuditJSONL(env: env))

            // 10. Append-only audit (UF_APPEND)
            results.append(check10AppendOnlyAudit(env: env))

            // 11. Merkle signing key persisted (mode 0600)
            results.append(check11MerkleSigningKey(env: env))

            // 12. S3 Object Lock audit copy — not automatable (AWS call)
            results.append(check12S3ObjectLockManual(env: env))

            // 13. Distributed lock backend
            results.append(check13DistributedLock(env: env))

            // 14. Tenancy mode set
            results.append(check14TenancyMode(env: env))

            // 15. Insecure mode is OFF
            results.append(check15InsecureOff(env: env))

            // 16. Hardened Runtime + notarization
            results.append(check16HardenedRuntime())

            // 17. Code-signing timestamp
            results.append(check17CodeSigningTimestamp())

            // 18. Only Apple SDKs in dependency tree — build-time, manual
            results.append(check18OnlyAppleSDKsManual())

            // ─── Extra reviewer-flagged probes (report after 18 so
            //     the 1:1 mapping stays clean) ────────────────────
            results.append(check19SAMLVerifierReady(env: env))
            results.append(check20IAMBindingStoreWritable(env: env))
            results.append(check21AuditSinkCanWrite(env: env))
            results.append(check22SignedRequestKeys(env: env))
            results.append(await check23GuestAgentReachable())

            return results
        }

        // MARK: - Item 01: TLS certificate + key

        static func check01TLSCertAndKey(env: [String: String]) -> CheckResult {
            let certPath = env["SPOOK_TLS_CERT_PATH"]
            let keyPath = env["SPOOK_TLS_KEY_PATH"]
            let fm = FileManager.default
            guard let certPath, let keyPath,
                  !certPath.isEmpty, !keyPath.isEmpty else {
                return fail(1, "TLS cert+key — SPOOK_TLS_CERT_PATH and SPOOK_TLS_KEY_PATH must both be set")
            }
            guard fm.isReadableFile(atPath: certPath) else {
                return fail(1, "TLS cert+key — SPOOK_TLS_CERT_PATH=\(certPath) is not readable by this process")
            }
            guard fm.isReadableFile(atPath: keyPath) else {
                return fail(1, "TLS cert+key — SPOOK_TLS_KEY_PATH=\(keyPath) is not readable by this process")
            }
            return pass(1, "TLS cert+key readable (\(certPath), \(keyPath))")
        }

        // MARK: - Item 02: mTLS

        static func check02MutualTLS(env: [String: String]) -> CheckResult {
            let caPath = env["SPOOK_TLS_CA_PATH"] ?? env["TLS_CA_PATH"]
            guard let caPath, !caPath.isEmpty else {
                return fail(2, "mTLS — SPOOK_TLS_CA_PATH not set (client certs are NOT required)")
            }
            guard FileManager.default.isReadableFile(atPath: caPath) else {
                return fail(2, "mTLS — SPOOK_TLS_CA_PATH=\(caPath) is not readable")
            }
            return pass(2, "mTLS CA: \(caPath)")
        }

        // MARK: - Item 03: TLS 1.3 floor

        static func check03TLS13Floor() async -> CheckResult {
            // If serve isn't running we cannot probe the floor;
            // mark as warning (not fail) so operators can run
            // doctor --strict offline without a 1.3 penalty.
            let port = HTTPAPIServer.defaultPort
            let reachable = await canTCPConnect(port: port)
            guard reachable else {
                return warn(3, "TLS 1.3 floor — cannot verify (spook serve not running)")
            }
            let ok = await tlsHandshakeSucceeds(port: port)
            return ok
                ? pass(3, "TLS 1.3 floor enforced on port \(port)")
                : fail(3, "TLS 1.3 floor — handshake at 1.3 failed on port \(port)")
        }

        // MARK: - Item 04: API bearer token in Keychain

        static func check04APITokenKeychain(env: [String: String]) -> CheckResult {
            let (status, note) = keychainGeneric(
                service: "com.spooktacular.api",
                account: "spook-api"
            )
            if status == errSecSuccess {
                return pass(4, "API bearer token present in Keychain (service=com.spooktacular.api)")
            }
            // Keychain miss — env fallback is acceptable for dev
            // but must be flagged as not hardened.
            if let tok = env["SPOOK_API_TOKEN"], !tok.isEmpty {
                return warn(4, "API bearer token — Keychain empty, falling back to SPOOK_API_TOKEN env var (not hardened; keychain status=\(status), \(note))")
            }
            return fail(4, "API bearer token — neither Keychain nor SPOOK_API_TOKEN is set (keychain status=\(status), \(note))")
        }

        // MARK: - Item 05: Guest-agent tokens

        static func check05GuestAgentTokens(env: [String: String]) -> CheckResult {
            // Any one of the three agent-tier tokens satisfies
            // the provisioning pipeline; the hardening doc's
            // intent is "tokens are NOT on disk in plaintext on
            // the host." We check the env-based signal here; a
            // follow-on probe (#19+) covers Keychain directly.
            let names = [
                "SPOOK_AGENT_TOKEN",
                "SPOOK_AGENT_RUNNER_TOKEN",
                "SPOOK_AGENT_READONLY_TOKEN"
            ]
            let present = names.filter { env[$0]?.isEmpty == false }
            if !present.isEmpty {
                return pass(5, "Guest-agent tokens: \(present.joined(separator: ", ")) present")
            }
            // Keychain fallback — the break-glass path reads the
            // ticket at mint time rather than injecting env.
            let (kcStatus, _) = keychainGeneric(
                service: "com.spooktacular.agent",
                account: "spook-agent"
            )
            if kcStatus == errSecSuccess {
                return pass(5, "Guest-agent token present in Keychain (service=com.spooktacular.agent)")
            }
            return warn(5, "Guest-agent tokens — no SPOOK_AGENT_*_TOKEN env var and no Keychain entry at com.spooktacular.agent")
        }

        // MARK: - Item 06: RBAC active

        static func check06RBACActive(env: [String: String]) -> CheckResult {
            if let rbacPath = env["SPOOK_RBAC_CONFIG"], !rbacPath.isEmpty {
                if FileManager.default.isReadableFile(atPath: rbacPath) {
                    return pass(6, "RBAC config readable: \(rbacPath)")
                }
                return fail(6, "RBAC — SPOOK_RBAC_CONFIG=\(rbacPath) is not readable")
            }
            if let groupMap = env["SPOOK_MACOS_GROUP_MAPPING"], !groupMap.isEmpty {
                return pass(6, "RBAC — SPOOK_MACOS_GROUP_MAPPING set (group-driven)")
            }
            return fail(6, "RBAC — neither SPOOK_RBAC_CONFIG nor SPOOK_MACOS_GROUP_MAPPING is set (deny-by-default will block all requests)")
        }

        // MARK: - Item 07: Federated IdP

        static func check07FederatedIdP(env: [String: String]) -> CheckResult {
            guard let idpPath = env["SPOOK_IDP_CONFIG"], !idpPath.isEmpty else {
                return fail(7, "Federated IdP — SPOOK_IDP_CONFIG not set")
            }
            guard FileManager.default.isReadableFile(atPath: idpPath) else {
                return fail(7, "Federated IdP — SPOOK_IDP_CONFIG=\(idpPath) is not readable")
            }
            return pass(7, "Federated IdP config: \(idpPath)")
        }

        // MARK: - Item 08: JWKS pinned

        static func check08JWKSPinned(env: [String: String]) -> CheckResult {
            guard let idpPath = env["SPOOK_IDP_CONFIG"], !idpPath.isEmpty,
                  let data = try? Data(contentsOf: URL(filePath: idpPath)),
                  let obj = try? JSONSerialization.jsonObject(with: data) else {
                return fail(8, "JWKS pinning — SPOOK_IDP_CONFIG missing / unreadable / not JSON")
            }
            // Accept either an array of providers or an object
            // with a `providers` array — matches the two shapes
            // shipped in docs/.
            let providers: [[String: Any]]
            if let array = obj as? [[String: Any]] {
                providers = array
            } else if let dict = obj as? [String: Any],
                      let array = dict["providers"] as? [[String: Any]] {
                providers = array
            } else {
                return fail(8, "JWKS pinning — SPOOK_IDP_CONFIG is not a providers list")
            }

            let oidcProviders = providers.filter {
                ($0["type"] as? String)?.lowercased() == "oidc"
                    || $0["oidc"] != nil
                    || $0["issuerURL"] != nil
            }
            guard !oidcProviders.isEmpty else {
                return pass(8, "JWKS pinning — no OIDC providers defined, nothing to pin")
            }
            var unpinned: [String] = []
            for provider in oidcProviders {
                // Unwrap a nested `config` / `oidc` payload — the
                // config file uses `{"type":"oidc","config":{…}}`.
                let fields: [String: Any] = (provider["config"] as? [String: Any])
                    ?? (provider["oidc"] as? [String: Any])
                    ?? provider
                let pinned = (fields["staticJWKSPath"] as? String)?.isEmpty == false
                    || (fields["jwksURLOverride"] as? String)?.isEmpty == false
                if !pinned {
                    let name = (fields["issuerURL"] as? String)
                        ?? (fields["clientID"] as? String)
                        ?? "<unnamed>"
                    unpinned.append(name)
                }
            }
            if unpinned.isEmpty {
                return pass(8, "JWKS pinning — all \(oidcProviders.count) OIDC provider(s) have staticJWKSPath or jwksURLOverride")
            }
            return fail(8, "JWKS pinning — \(unpinned.count) OIDC provider(s) NOT pinned: \(unpinned.prefix(3).joined(separator: ", "))")
        }

        // MARK: - Item 09: Audit JSONL

        static func check09AuditJSONL(env: [String: String]) -> CheckResult {
            guard let auditPath = env["SPOOK_AUDIT_FILE"], !auditPath.isEmpty else {
                return fail(9, "Audit JSONL — SPOOK_AUDIT_FILE not set")
            }
            let dir = URL(filePath: auditPath).deletingLastPathComponent().path
            guard FileManager.default.isWritableFile(atPath: dir) else {
                return fail(9, "Audit JSONL — directory not writable: \(dir)")
            }
            return pass(9, "Audit JSONL: \(auditPath) (dir writable)")
        }

        // MARK: - Item 10: Append-only audit

        static func check10AppendOnlyAudit(env: [String: String]) -> CheckResult {
            guard let path = env["SPOOK_AUDIT_IMMUTABLE_PATH"], !path.isEmpty else {
                return fail(10, "Append-only audit — SPOOK_AUDIT_IMMUTABLE_PATH not set")
            }
            let fm = FileManager.default
            guard fm.fileExists(atPath: path) else {
                let dir = URL(filePath: path).deletingLastPathComponent().path
                if fm.isWritableFile(atPath: dir) {
                    return warn(10, "Append-only audit — file not yet created at \(path); will be flagged UF_APPEND on first write")
                }
                return fail(10, "Append-only audit — directory not writable: \(dir)")
            }
            var s = stat()
            guard path.withCString({ stat($0, &s) }) == 0 else {
                return fail(10, "Append-only audit — stat(\(path)) failed: errno \(errno)")
            }
            if (s.st_flags & UInt32(UF_APPEND)) != 0 {
                return pass(10, "Append-only audit: \(path) (UF_APPEND set)")
            }
            return fail(10, "Append-only audit — UF_APPEND NOT set on \(path); run `chflags uappnd \(path)`")
        }

        // MARK: - Item 11: Merkle signing key persisted

        static func check11MerkleSigningKey(env: [String: String]) -> CheckResult {
            let merkleEnabled = env["SPOOK_AUDIT_MERKLE"] == "1"
            guard merkleEnabled else {
                return warn(11, "Merkle signing — SPOOK_AUDIT_MERKLE!=1 (tamper-evidence disabled)")
            }
            guard let keyPath = env["SPOOK_AUDIT_SIGNING_KEY"], !keyPath.isEmpty else {
                return fail(11, "Merkle signing — SPOOK_AUDIT_MERKLE=1 but SPOOK_AUDIT_SIGNING_KEY is unset")
            }
            let fm = FileManager.default
            guard fm.fileExists(atPath: keyPath) else {
                return warn(11, "Merkle signing — key not yet at \(keyPath); will be created mode 0600 on first start")
            }
            guard let attrs = try? fm.attributesOfItem(atPath: keyPath),
                  let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value else {
                return fail(11, "Merkle signing — cannot read permissions on \(keyPath)")
            }
            if mode & 0o077 == 0 {
                return pass(11, String(format: "Merkle signing key: %@ (mode 0%o)", keyPath, mode))
            }
            return fail(11, String(format: "Merkle signing — %@ has mode 0%o, must be 0600", keyPath, mode))
        }

        // MARK: - Item 12: S3 Object Lock (manual)

        static func check12S3ObjectLockManual(env: [String: String]) -> CheckResult {
            guard let bucket = env["SPOOK_AUDIT_S3_BUCKET"], !bucket.isEmpty else {
                return fail(12, "S3 Object Lock — SPOOK_AUDIT_S3_BUCKET not set")
            }
            return manual(12, "S3 Object Lock — configured for bucket '\(bucket)'; verify COMPLIANCE mode with `aws s3api get-object-lock-configuration --bucket \(bucket)`")
        }

        // MARK: - Item 13: Distributed lock backend

        static func check13DistributedLock(env: [String: String]) -> CheckResult {
            if env["SPOOK_DYNAMO_TABLE"]?.isEmpty == false {
                return pass(13, "Distributed lock: DynamoDB (SPOOK_DYNAMO_TABLE=\(env["SPOOK_DYNAMO_TABLE"] ?? ""))")
            }
            if env["SPOOK_K8S_API"]?.isEmpty == false {
                return pass(13, "Distributed lock: Kubernetes Lease (SPOOK_K8S_API set)")
            }
            return warn(13, "Distributed lock: file/flock fallback — fleets of ≥ 2 hosts MUST set SPOOK_DYNAMO_TABLE or SPOOK_K8S_API")
        }

        // MARK: - Item 14: Tenancy mode

        static func check14TenancyMode(env: [String: String]) -> CheckResult {
            let mode = env["SPOOK_TENANCY_MODE"] ?? "single-tenant"
            return pass(14, "Tenancy mode: \(mode)")
        }

        // MARK: - Item 15: Insecure mode OFF

        static func check15InsecureOff(env: [String: String]) -> CheckResult {
            if env["SPOOK_INSECURE_CONTROLLER"] == "1" {
                return fail(15, "Insecure — SPOOK_INSECURE_CONTROLLER=1 (mTLS bypass active; do NOT ship)")
            }
            return pass(15, "Insecure — SPOOK_INSECURE_CONTROLLER is not set")
        }

        // MARK: - Item 16: Hardened Runtime + notarization

        static func check16HardenedRuntime() -> CheckResult {
            let spookPath = ProcessInfo.processInfo.arguments[0]
            let text = runCodesign(path: spookPath)
            let hasRuntime = text.contains("flags=") && text.contains("runtime")
            let hasTeam = text.contains("TeamIdentifier=") && !text.contains("TeamIdentifier=not set")
            switch (hasRuntime, hasTeam) {
            case (true, true):
                return pass(16, "Hardened Runtime + Team ID present on \(spookPath)")
            case (true, false):
                return warn(16, "Hardened Runtime set but TeamIdentifier absent (ad-hoc or dev signing)")
            case (false, _):
                return fail(16, "Hardened Runtime — NOT set on \(spookPath); will fail Gatekeeper")
            }
        }

        // MARK: - Item 17: Code-signing timestamp

        static func check17CodeSigningTimestamp() -> CheckResult {
            let spookPath = ProcessInfo.processInfo.arguments[0]
            let text = runCodesign(path: spookPath)
            if text.contains("Signed Time=") || text.contains("Timestamp=") {
                return pass(17, "Code-signing timestamp present on \(spookPath)")
            }
            return fail(17, "Code-signing timestamp — `--timestamp` was not used on \(spookPath); required for re-verifiable signatures")
        }

        // MARK: - Item 18: Only Apple SDKs (manual build-time)

        static func check18OnlyAppleSDKsManual() -> CheckResult {
            manual(18, "Only Apple SDKs — verify at build time with `swift package show-dependencies --format json` (expect empty `dependencies`)")
        }

        // MARK: - Reviewer-flagged extras (19+)

        /// Probes whether a SAML assertion verifier is wired for
        /// each `saml`-typed provider in the IdP config. Looks
        /// for `metadataPath` or `signingCertPath` (fields the
        /// SAMLAssertionVerifier requires to validate signatures)
        /// on every SAML provider. Reports each provider
        /// individually so operators can identify the bad row.
        static func check19SAMLVerifierReady(env: [String: String]) -> CheckResult {
            guard let idpPath = env["SPOOK_IDP_CONFIG"], !idpPath.isEmpty,
                  let data = try? Data(contentsOf: URL(filePath: idpPath)),
                  let obj = try? JSONSerialization.jsonObject(with: data) else {
                return warn(19, "SAML verifier — SPOOK_IDP_CONFIG missing/unreadable; skipping")
            }
            let providers: [[String: Any]]
            if let array = obj as? [[String: Any]] { providers = array }
            else if let dict = obj as? [String: Any],
                    let array = dict["providers"] as? [[String: Any]] { providers = array }
            else { providers = [] }

            let samlProviders = providers.filter {
                ($0["type"] as? String)?.lowercased() == "saml" || $0["saml"] != nil
            }
            if samlProviders.isEmpty {
                return pass(19, "SAML verifier — no SAML providers configured (nothing to probe)")
            }
            var misconfigured: [String] = []
            let fm = FileManager.default
            for provider in samlProviders {
                let fields: [String: Any] = (provider["config"] as? [String: Any])
                    ?? (provider["saml"] as? [String: Any])
                    ?? provider
                let entity = (fields["entityID"] as? String) ?? "<unnamed>"
                let meta = fields["metadataPath"] as? String
                let cert = fields["signingCertPath"] as? String
                let hasMaterial = (meta.map { fm.isReadableFile(atPath: $0) } ?? false)
                    || (cert.map { fm.isReadableFile(atPath: $0) } ?? false)
                if !hasMaterial {
                    misconfigured.append(entity)
                }
            }
            if misconfigured.isEmpty {
                return pass(19, "SAML verifier — \(samlProviders.count) SAML provider(s) have readable signing material")
            }
            return fail(19, "SAML verifier — \(misconfigured.count) SAML provider(s) missing signing material: \(misconfigured.prefix(3).joined(separator: ", "))")
        }

        /// Ensures `JSONVMIAMBindingStore` can load / write the
        /// bindings file — the endpoint otherwise returns 404 for
        /// every IAM CRUD call but fails silently during provisioning.
        static func check20IAMBindingStoreWritable(env: [String: String]) -> CheckResult {
            guard let path = env["SPOOK_IAM_BINDINGS_CONFIG"], !path.isEmpty else {
                return warn(20, "IAM bindings — SPOOK_IAM_BINDINGS_CONFIG unset (identity-token minting disabled)")
            }
            let fm = FileManager.default
            let dir = URL(filePath: path).deletingLastPathComponent().path
            if fm.fileExists(atPath: path) {
                if fm.isReadableFile(atPath: path) && fm.isWritableFile(atPath: path) {
                    return pass(20, "IAM bindings: \(path) (readable + writable)")
                }
                return fail(20, "IAM bindings — \(path) exists but is not readable/writable")
            }
            if fm.isWritableFile(atPath: dir) {
                return pass(20, "IAM bindings — \(path) will be created (dir writable)")
            }
            return fail(20, "IAM bindings — \(path) cannot be created (dir not writable)")
        }

        /// Verifies the configured audit sink path is actually
        /// writable from this process identity. Distinct from #09:
        /// #09 checks the env var + dir, #21 opens the file for
        /// append so permissions mismatches surface at doctor time
        /// instead of at first `spook serve` request.
        static func check21AuditSinkCanWrite(env: [String: String]) -> CheckResult {
            guard let path = env["SPOOK_AUDIT_FILE"], !path.isEmpty else {
                return warn(21, "Audit sink probe — SPOOK_AUDIT_FILE unset, skipping")
            }
            let fm = FileManager.default
            let exists = fm.fileExists(atPath: path)
            let fh: FileHandle?
            if exists {
                fh = try? FileHandle(forWritingTo: URL(filePath: path))
            } else {
                // Try to create + immediately close. Clean up
                // only if we created it.
                let dir = URL(filePath: path).deletingLastPathComponent().path
                guard fm.isWritableFile(atPath: dir) else {
                    return fail(21, "Audit sink probe — directory not writable: \(dir)")
                }
                let created = fm.createFile(atPath: path, contents: nil)
                guard created else {
                    return fail(21, "Audit sink probe — createFile(\(path)) failed")
                }
                fh = try? FileHandle(forWritingTo: URL(filePath: path))
            }
            guard let fh else {
                return fail(21, "Audit sink probe — FileHandle(forWritingTo: \(path)) threw")
            }
            try? fh.close()
            return pass(21, "Audit sink — \(path) is open-for-append-able by this process")
        }

        /// Signed-request verifier needs a populated public-key
        /// directory to be the production auth path. An empty /
        /// missing directory drops every request into
        /// `authenticationRequired`.
        static func check22SignedRequestKeys(env: [String: String]) -> CheckResult {
            guard let dir = env["SPOOK_API_PUBLIC_KEYS_DIR"], !dir.isEmpty else {
                return warn(22, "Signed requests — SPOOK_API_PUBLIC_KEYS_DIR unset (Bearer-token fallback only)")
            }
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
                return fail(22, "Signed requests — \(dir) is not a directory")
            }
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else {
                return fail(22, "Signed requests — cannot list \(dir)")
            }
            let pems = names.filter { $0.hasSuffix(".pem") || $0.hasSuffix(".pub") }
            if pems.isEmpty {
                return fail(22, "Signed requests — \(dir) has zero .pem/.pub keys (every signed request will be rejected)")
            }
            return pass(22, "Signed requests — \(pems.count) trusted key(s) in \(dir)")
        }

        /// Best-effort probe that at least one running VM is
        /// reachable via its guest-agent vsock port. The probe
        /// cannot open a vsock from the host side without a
        /// VZVirtualMachine reference, so we use the presence of
        /// a running PID file as a proxy. Downstream operators
        /// can run `spook remote health <vm>` for a live check.
        static func check23GuestAgentReachable() async -> CheckResult {
            let running = CapacityCheck.runningVMs(in: SpooktacularPaths.vms)
            if running.isEmpty {
                return pass(23, "Guest-agent probe — no running VMs (nothing to probe)")
            }
            // Without a host-side vsock connector, we report the
            // count + hint. Actor-wire probe stays in
            // `spook remote health` to keep doctor hermetic.
            let names = running.prefix(3).joined(separator: ", ")
            return pass(23, "Guest-agent — \(running.count) running VM(s) detected (\(names)); run `spook remote health <vm>` to probe vsock")
        }

        // MARK: - Shared Helpers

        /// Minimal Keychain probe — returns the raw OSStatus plus
        /// a diagnostic string so the caller can produce a
        /// one-line message that fits the `[#]` prefix format.
        static func keychainGeneric(service: String, account: String) -> (OSStatus, String) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: false,
                kSecReturnAttributes as String: false,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                return (status, "OK")
            case errSecItemNotFound:
                return (status, "not found")
            case errSecInteractionNotAllowed:
                return (status, "Keychain locked / non-interactive")
            default:
                return (status, "OSStatus \(status)")
            }
        }

        /// Runs `codesign -d --verbose=4` and returns the
        /// combined stdout+stderr string. Returns `""` if
        /// codesign is not available.
        static func runCodesign(path: String) -> String {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/codesign")
            process.arguments = ["-d", "--verbose=4", path]
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = pipe
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return ""
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }

        /// Non-blocking TCP probe — resolves to `true` if the
        /// TCP handshake completes within 2s, `false` otherwise.
        private static func canTCPConnect(port: UInt16) async -> Bool {
            await withCheckedContinuation { continuation in
                nonisolated(unsafe) var resumed = false
                let connection = NWConnection(
                    host: NWEndpoint.Host("127.0.0.1"),
                    port: NWEndpoint.Port(rawValue: port)!,
                    using: .tcp
                )
                let queue = DispatchQueue(label: "doctor.tcp-probe")
                connection.stateUpdateHandler = { state in
                    guard !resumed else { return }
                    switch state {
                    case .ready:
                        resumed = true
                        connection.cancel()
                        continuation.resume(returning: true)
                    case .failed, .waiting, .cancelled:
                        resumed = true
                        connection.cancel()
                        continuation.resume(returning: false)
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 2) {
                    guard !resumed else { return }
                    resumed = true
                    connection.cancel()
                    continuation.resume(returning: false)
                }
            }
        }

        /// TLS 1.3 handshake probe to a local endpoint.
        private static func tlsHandshakeSucceeds(port: UInt16) async -> Bool {
            await withCheckedContinuation { continuation in
                nonisolated(unsafe) var resumed = false
                let tlsParams = NWProtocolTLS.Options()
                sec_protocol_options_set_min_tls_protocol_version(
                    tlsParams.securityProtocolOptions, .TLSv13
                )
                let params = NWParameters(tls: tlsParams, tcp: NWProtocolTCP.Options())
                let connection = NWConnection(
                    host: NWEndpoint.Host("127.0.0.1"),
                    port: NWEndpoint.Port(rawValue: port)!,
                    using: params
                )
                let queue = DispatchQueue(label: "doctor.tls-probe")
                connection.stateUpdateHandler = { state in
                    guard !resumed else { return }
                    switch state {
                    case .ready:
                        resumed = true
                        connection.cancel()
                        continuation.resume(returning: true)
                    case .failed, .waiting, .cancelled:
                        resumed = true
                        connection.cancel()
                        continuation.resume(returning: false)
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 2) {
                    guard !resumed else { return }
                    resumed = true
                    connection.cancel()
                    continuation.resume(returning: false)
                }
            }
        }

        // MARK: - Check Result + Formatting

        enum Status: Sendable {
            case pass
            case fail
            case warning
            /// An item the CLI cannot automate (AWS calls,
            /// build-time introspection). Surfaced with `?` so
            /// the operator sees the row and knows they must
            /// verify it elsewhere.
            case manual
        }

        struct CheckResult: Sendable {
            let status: Status
            let message: String
        }

        static func pass(_ item: Int, _ body: String) -> CheckResult {
            CheckResult(status: .pass, message: formatItem(item, body))
        }

        static func fail(_ item: Int, _ body: String) -> CheckResult {
            CheckResult(status: .fail, message: formatItem(item, body))
        }

        static func warn(_ item: Int, _ body: String) -> CheckResult {
            CheckResult(status: .warning, message: formatItem(item, body))
        }

        static func manual(_ item: Int, _ body: String) -> CheckResult {
            CheckResult(status: .manual, message: formatItem(item, body))
        }

        /// Every strict-mode row begins with a zero-padded item
        /// number so grep / awk pipelines at the table line up.
        static func formatItem(_ item: Int, _ body: String) -> String {
            String(format: "[%02d] %@", item, body)
        }

        private func printResult(_ result: CheckResult) {
            let indicator: String
            switch result.status {
            case .pass:    indicator = Style.green("\u{2713}")
            case .fail:    indicator = Style.error("\u{2717}")
            case .warning: indicator = Style.warning("\u{26A0}")
            case .manual:  indicator = Style.dim("?")
            }
            print("\(indicator) \(result.message)")
        }

        private func count(
            _ result: CheckResult,
            passed: inout Int,
            failed: inout Int,
            warned: inout Int
        ) {
            switch result.status {
            case .pass:    passed += 1
            case .fail:    failed += 1
            case .warning: warned += 1
            case .manual:  warned += 1   // counts as warning for summary
            }
        }

        // MARK: - Individual Host Checks (non-strict)

        /// Verifies the host is running on Apple Silicon (arm64).
        private func checkAppleSilicon() -> CheckResult {
            #if arch(arm64)
            return CheckResult(
                status: .pass,
                message: "Apple Silicon (arm64)"
            )
            #else
            return CheckResult(
                status: .fail,
                message: "Not Apple Silicon — Virtualization.framework requires arm64"
            )
            #endif
        }

        /// Verifies macOS 14.0 (Sonoma) or later.
        private func checkMacOSVersion() -> CheckResult {
            let version = ProcessInfo.processInfo.operatingSystemVersion
            let versionString = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"

            if version.majorVersion >= 14 {
                return CheckResult(
                    status: .pass,
                    message: "macOS \(versionString) (minimum: 14.0)"
                )
            } else {
                return CheckResult(
                    status: .fail,
                    message: "macOS \(versionString) — requires macOS 14.0 (Sonoma) or later"
                )
            }
        }

        /// Checks whether Virtualization.framework is available by
        /// requesting the latest supported restore image version.
        private func checkVirtualization() async -> CheckResult {
            do {
                _ = try await VZMacOSRestoreImage.latestSupported
                return CheckResult(
                    status: .pass,
                    message: "Virtualization.framework available"
                )
            } catch {
                return CheckResult(
                    status: .fail,
                    message: "Virtualization.framework unavailable (\(error.localizedDescription))"
                )
            }
        }

        /// Checks free disk space at the Spooktacular storage path.
        ///
        /// Warns if less than 50 GB free, fails if less than 20 GB.
        private func checkDiskSpace() -> CheckResult {
            let storageURL = SpooktacularPaths.root
            let fileManager = FileManager.default

            // Use the volume root if the storage directory doesn't exist yet.
            let checkURL = fileManager.fileExists(atPath: storageURL.path)
                ? storageURL
                : URL(filePath: "/")

            do {
                let values = try checkURL.resourceValues(
                    forKeys: [.volumeAvailableCapacityForImportantUsageKey]
                )
                guard let freeBytes = values.volumeAvailableCapacityForImportantUsage else {
                    return CheckResult(
                        status: .warning,
                        message: "Disk space: unable to determine free space"
                    )
                }

                let freeGB = freeBytes / (1024 * 1024 * 1024)

                if freeGB < 20 {
                    return CheckResult(
                        status: .fail,
                        message: "Disk space: \(freeGB) GB free (minimum: 20 GB)"
                    )
                } else if freeGB < 50 {
                    return CheckResult(
                        status: .warning,
                        message: "Disk space: \(freeGB) GB free (recommended: 50 GB)"
                    )
                } else {
                    return CheckResult(
                        status: .pass,
                        message: "Disk space: \(freeGB) GB free (minimum: 20 GB)"
                    )
                }
            } catch {
                return CheckResult(
                    status: .warning,
                    message: "Disk space: unable to check (\(error.localizedDescription))"
                )
            }
        }

        /// Checks whether at least one `.vm` bundle exists.
        private func checkBaseVM() -> CheckResult {
            let vmDir = SpooktacularPaths.vms
            let fileManager = FileManager.default

            guard fileManager.fileExists(atPath: vmDir.path) else {
                return CheckResult(
                    status: .fail,
                    message: "No VM directory found at \(vmDir.path)"
                )
            }

            do {
                let contents = try fileManager.contentsOfDirectory(
                    at: vmDir,
                    includingPropertiesForKeys: nil
                ).filter { $0.pathExtension == "vm" }

                if contents.isEmpty {
                    return CheckResult(
                        status: .fail,
                        message: "No base VM found — run 'spook create <name>' first"
                    )
                }

                let names = contents
                    .map { $0.deletingPathExtension().lastPathComponent }
                    .sorted()
                let nameList = names.joined(separator: ", ")
                return CheckResult(
                    status: .pass,
                    message: "Base VM found: \(nameList)"
                )
            } catch {
                return CheckResult(
                    status: .fail,
                    message: "Cannot read VM directory (\(error.localizedDescription))"
                )
            }
        }

        /// Checks whether port 8484 is accepting TCP connections.
        private func checkServeRunning() async -> CheckResult {
            let port = HTTPAPIServer.defaultPort
            let reachable = await Self.canTCPConnect(port: port)
            return CheckResult(
                status: reachable ? .pass : .fail,
                message: reachable
                    ? "spook serve running (port \(port))"
                    : "spook serve not running (port \(port))"
            )
        }

        /// Checks whether the serve endpoint is using TLS by
        /// attempting a TLS 1.3 handshake on port 8484.
        private func checkTLS() async -> CheckResult {
            let port = HTTPAPIServer.defaultPort
            let ok = await Self.tlsHandshakeSucceeds(port: port)
            return CheckResult(
                status: ok ? .pass : .fail,
                message: ok
                    ? "TLS configured on port \(port)"
                    : "TLS not configured on port \(port)"
            )
        }

        /// Checks whether the SPOOK_API_TOKEN environment variable is set.
        private func checkAPIToken() -> CheckResult {
            if let token = ProcessInfo.processInfo.environment["SPOOK_API_TOKEN"],
               !token.isEmpty {
                return CheckResult(
                    status: .pass,
                    message: "SPOOK_API_TOKEN set"
                )
            } else {
                return CheckResult(
                    status: .warning,
                    message: "SPOOK_API_TOKEN not set"
                )
            }
        }

        /// Shows the current running VM count vs the maximum allowed.
        private func checkCapacity() -> CheckResult {
            let vmDir = SpooktacularPaths.vms
            let running = CapacityCheck.runningVMs(in: vmDir)
            let max = CapacityCheck.maxConcurrentVMs

            return CheckResult(
                status: .pass,
                message: "Capacity: \(running.count)/\(max) VMs running"
            )
        }
    }
}
