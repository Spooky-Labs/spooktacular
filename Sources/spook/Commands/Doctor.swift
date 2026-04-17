import ArgumentParser
import Foundation
import Network
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
                for result in strictProductionChecks() {
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

        // MARK: - Strict mode: production controls

        /// Deterministic, filesystem + env-var checks covering every
        /// production control in `docs/DEPLOYMENT_HARDENING.md`. Kept
        /// synchronous and free of network I/O so `--strict` runs in
        /// under a second and is safe to invoke from CI.
        private func strictProductionChecks() -> [CheckResult] {
            let env = ProcessInfo.processInfo.environment
            var results: [CheckResult] = []

            // mTLS CA path
            let caPath = env["SPOOK_TLS_CA_PATH"] ?? env["TLS_CA_PATH"]
            if let caPath, FileManager.default.fileExists(atPath: caPath) {
                results.append(CheckResult(status: .pass, message: "mTLS CA: \(caPath)"))
            } else {
                results.append(CheckResult(status: .fail, message: "mTLS CA not set — export SPOOK_TLS_CA_PATH to enable client-cert verification"))
            }

            // RBAC
            if let rbacPath = env["SPOOK_RBAC_CONFIG"], FileManager.default.fileExists(atPath: rbacPath) {
                results.append(CheckResult(status: .pass, message: "RBAC config: \(rbacPath)"))
            } else {
                results.append(CheckResult(status: .fail, message: "SPOOK_RBAC_CONFIG missing — RBAC disabled, everything authorized"))
            }

            // IdP
            if let idpPath = env["SPOOK_IDP_CONFIG"], FileManager.default.fileExists(atPath: idpPath) {
                results.append(CheckResult(status: .pass, message: "Federated IdP config: \(idpPath)"))
            } else {
                results.append(CheckResult(status: .warning, message: "SPOOK_IDP_CONFIG missing — federated identity disabled"))
            }

            // Audit JSONL
            if let auditPath = env["SPOOK_AUDIT_FILE"] {
                let dir = URL(filePath: auditPath).deletingLastPathComponent().path
                if FileManager.default.isWritableFile(atPath: dir) {
                    results.append(CheckResult(status: .pass, message: "Audit JSONL: \(auditPath) (writable)"))
                } else {
                    results.append(CheckResult(status: .fail, message: "Audit JSONL path's directory is not writable: \(dir)"))
                }
            } else {
                results.append(CheckResult(status: .fail, message: "SPOOK_AUDIT_FILE missing — structured audit disabled"))
            }

            // Append-only audit file kernel flag
            if let immutable = env["SPOOK_AUDIT_IMMUTABLE_PATH"] {
                results.append(checkAppendOnlyFlag(path: immutable))
            } else {
                results.append(CheckResult(status: .warning, message: "SPOOK_AUDIT_IMMUTABLE_PATH missing — kernel-enforced append-only audit disabled"))
            }

            // Merkle signing key
            if env["SPOOK_AUDIT_MERKLE"] == "1" {
                if let keyPath = env["SPOOK_AUDIT_SIGNING_KEY"] {
                    results.append(checkSigningKeyPerms(path: keyPath))
                } else {
                    results.append(CheckResult(status: .fail, message: "SPOOK_AUDIT_MERKLE=1 but SPOOK_AUDIT_SIGNING_KEY is unset"))
                }
            } else {
                results.append(CheckResult(status: .warning, message: "Merkle tamper-evidence disabled (SPOOK_AUDIT_MERKLE!=1)"))
            }

            // Distributed lock backend
            if env["SPOOK_DYNAMO_TABLE"]?.isEmpty == false {
                results.append(CheckResult(status: .pass, message: "Distributed lock: DynamoDB (cross-region)"))
            } else if env["SPOOK_K8S_API"]?.isEmpty == false {
                results.append(CheckResult(status: .pass, message: "Distributed lock: Kubernetes Lease"))
            } else {
                results.append(CheckResult(status: .warning, message: "Distributed lock: file/flock (single-host only — fleets ≥2 hosts MUST set SPOOK_DYNAMO_TABLE or SPOOK_K8S_API)"))
            }

            // Tenancy mode
            let mode = env["SPOOK_TENANCY_MODE"] ?? "single-tenant"
            results.append(CheckResult(status: .pass, message: "Tenancy mode: \(mode)"))

            // Insecure flag not set
            if env["SPOOK_INSECURE_CONTROLLER"] == "1" {
                results.append(CheckResult(status: .fail, message: "SPOOK_INSECURE_CONTROLLER=1 — mTLS bypass active, do NOT ship this way"))
            } else {
                results.append(CheckResult(status: .pass, message: "Insecure-controller bypass is OFF"))
            }

            // Hardened Runtime + notarization on the spook binary
            results.append(checkCodesignHardening())

            // Bundle protection class per the data-at-rest plan
            results.append(checkBundleProtection())

            return results
        }

        /// On portable Macs, confirms VM bundles carry the
        /// `.completeUntilFirstUserAuthentication` protection
        /// class per docs/DATA_AT_REST.md. On desktops this is
        /// expected to be `.none` and passes.
        private func checkBundleProtection() -> CheckResult {
            let (recommended, policy) = BundleProtection.recommendedPolicy()
            let vmDir = SpooktacularPaths.vms
            let fm = FileManager.default
            guard fm.fileExists(atPath: vmDir.path),
                  let contents = try? fm.contentsOfDirectory(at: vmDir, includingPropertiesForKeys: nil)
            else {
                return CheckResult(status: .pass, message: "Bundle protection: no bundles yet — new bundles will apply \(recommended.displayName) [\(policy)]")
            }
            let bundles = contents.filter { $0.pathExtension == "vm" }
            guard !bundles.isEmpty else {
                return CheckResult(status: .pass, message: "Bundle protection: no bundles yet — new bundles will apply \(recommended.displayName) [\(policy)]")
            }

            var unprotected: [String] = []
            for bundle in bundles {
                let current = (try? BundleProtection.current(at: bundle)) ?? .none
                if current != recommended {
                    unprotected.append(bundle.deletingPathExtension().lastPathComponent)
                }
            }
            if unprotected.isEmpty {
                return CheckResult(status: .pass, message: "Bundle protection: \(bundles.count) bundle(s) at \(recommended.displayName) [\(policy)]")
            }
            let list = unprotected.prefix(5).joined(separator: ", ")
            let more = unprotected.count > 5 ? " (+\(unprotected.count - 5) more)" : ""
            return CheckResult(
                status: .warning,
                message: "Bundle protection: \(unprotected.count) bundle(s) not at \(recommended.displayName): \(list)\(more). Run `spook bundle protect --all` to migrate."
            )
        }

        /// Verifies `UF_APPEND` is set on the target file, or — if
        /// the file does not yet exist — that its directory is
        /// writable so the audit store can create + flag it.
        private func checkAppendOnlyFlag(path: String) -> CheckResult {
            let fm = FileManager.default
            guard fm.fileExists(atPath: path) else {
                let dir = URL(filePath: path).deletingLastPathComponent().path
                if fm.isWritableFile(atPath: dir) {
                    return CheckResult(status: .warning, message: "Append-only audit file does not exist yet; will be created at \(path) on first write")
                }
                return CheckResult(status: .fail, message: "Append-only audit file's directory is not writable: \(dir)")
            }
            // Use stat(2) to read st_flags — the Swift URL API does
            // not expose UF_APPEND directly.
            var s = stat()
            guard path.withCString({ stat($0, &s) }) == 0 else {
                return CheckResult(status: .fail, message: "Cannot stat \(path): errno \(errno)")
            }
            if (s.st_flags & UInt32(UF_APPEND)) != 0 {
                return CheckResult(status: .pass, message: "Append-only audit file: \(path) (UF_APPEND set)")
            }
            return CheckResult(status: .fail, message: "Audit file exists but UF_APPEND is NOT set: \(path) — run `chflags uappnd \(path)` or restart spook serve to let the store set it")
        }

        /// Confirms the Merkle signing key is present and mode 0600.
        private func checkSigningKeyPerms(path: String) -> CheckResult {
            let fm = FileManager.default
            guard fm.fileExists(atPath: path) else {
                return CheckResult(status: .warning, message: "Merkle signing key does not exist yet; will be created at \(path) on first start (mode 0600)")
            }
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value else {
                return CheckResult(status: .fail, message: "Cannot read permissions on \(path)")
            }
            if mode & 0o077 == 0 {
                return CheckResult(status: .pass, message: String(format: "Merkle signing key: %@ (mode 0%o)", path, mode))
            }
            return CheckResult(status: .fail, message: String(format: "Merkle signing key at %@ has mode 0%o — must be 0600; `chmod 600 %@`", path, mode, path))
        }

        /// Runs `codesign -d --verbose=4 <spook>` and checks for the
        /// Hardened Runtime flag and a non-ad-hoc Team ID. A failure
        /// here doesn't block local dev but does block any SOC 2 /
        /// App Store Connect review.
        private func checkCodesignHardening() -> CheckResult {
            let spookPath = ProcessInfo.processInfo.arguments[0]
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/codesign")
            process.arguments = ["-d", "--verbose=4", spookPath]
            let out = Pipe()
            process.standardError = out
            process.standardOutput = out
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return CheckResult(status: .warning, message: "Could not invoke /usr/bin/codesign: \(error.localizedDescription)")
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            let hasRuntime = text.contains("flags=") && text.contains("runtime")
            let hasTeamID = text.contains("TeamIdentifier=") && !text.contains("TeamIdentifier=not set")
            switch (hasRuntime, hasTeamID) {
            case (true, true):
                return CheckResult(status: .pass, message: "Hardened Runtime + Team ID present on spook binary")
            case (true, false):
                return CheckResult(status: .warning, message: "Hardened Runtime set but Team ID absent (ad-hoc or dev signing)")
            case (false, _):
                return CheckResult(status: .fail, message: "spook binary is NOT notarized with Hardened Runtime — will fail Gatekeeper on distribution")
            }
        }

        // MARK: - Check Result

        private enum Status {
            case pass
            case fail
            case warning
        }

        private struct CheckResult {
            let status: Status
            let message: String
        }

        // MARK: - Output Helpers

        private func printResult(_ result: CheckResult) {
            let indicator: String
            switch result.status {
            case .pass:
                indicator = Style.green("\u{2713}")
            case .fail:
                indicator = Style.error("\u{2717}")
            case .warning:
                indicator = Style.warning("\u{26A0}")
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
            case .pass: passed += 1
            case .fail: failed += 1
            case .warning: warned += 1
            }
        }

        // MARK: - Individual Checks

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

            return await withCheckedContinuation { continuation in
                nonisolated(unsafe) var resumed = false
                let connection = NWConnection(
                    host: NWEndpoint.Host("127.0.0.1"),
                    port: NWEndpoint.Port(rawValue: port)!,
                    using: .tcp
                )

                let queue = DispatchQueue(label: "doctor.port-check")

                connection.stateUpdateHandler = { state in
                    guard !resumed else { return }
                    switch state {
                    case .ready:
                        resumed = true
                        connection.cancel()
                        continuation.resume(returning: CheckResult(
                            status: .pass,
                            message: "spook serve running (port \(port))"
                        ))
                    case .failed:
                        resumed = true
                        connection.cancel()
                        continuation.resume(returning: CheckResult(
                            status: .fail,
                            message: "spook serve not running (port \(port))"
                        ))
                    case .waiting:
                        resumed = true
                        connection.cancel()
                        continuation.resume(returning: CheckResult(
                            status: .fail,
                            message: "spook serve not running (port \(port))"
                        ))
                    default:
                        break
                    }
                }

                connection.start(queue: queue)

                // Timeout after 2 seconds.
                queue.asyncAfter(deadline: .now() + 2) {
                    guard !resumed else { return }
                    resumed = true
                    connection.cancel()
                    continuation.resume(returning: CheckResult(
                        status: .fail,
                        message: "spook serve not running (port \(port))"
                    ))
                }
            }
        }

        /// Checks whether the serve endpoint is using TLS by
        /// attempting a TLS handshake on port 8484.
        private func checkTLS() async -> CheckResult {
            let port = HTTPAPIServer.defaultPort

            return await withCheckedContinuation { continuation in
                nonisolated(unsafe) var resumed = false
                // Doctor handshakes at the same floor the server will
                // accept; otherwise doctor reports success against a
                // downgraded cipher and the operator believes TLS 1.3
                // is working when in fact 1.2 was negotiated.
                let tlsParams = NWProtocolTLS.Options()
                sec_protocol_options_set_min_tls_protocol_version(
                    tlsParams.securityProtocolOptions, .TLSv13
                )
                let tcpOptions = NWProtocolTCP.Options()
                let params = NWParameters(tls: tlsParams, tcp: tcpOptions)

                let connection = NWConnection(
                    host: NWEndpoint.Host("127.0.0.1"),
                    port: NWEndpoint.Port(rawValue: port)!,
                    using: params
                )

                let queue = DispatchQueue(label: "doctor.tls-check")

                connection.stateUpdateHandler = { state in
                    guard !resumed else { return }
                    switch state {
                    case .ready:
                        resumed = true
                        connection.cancel()
                        continuation.resume(returning: CheckResult(
                            status: .pass,
                            message: "TLS configured on port \(port)"
                        ))
                    case .failed:
                        resumed = true
                        connection.cancel()
                        continuation.resume(returning: CheckResult(
                            status: .fail,
                            message: "TLS not configured on port \(port)"
                        ))
                    case .waiting:
                        resumed = true
                        connection.cancel()
                        continuation.resume(returning: CheckResult(
                            status: .fail,
                            message: "TLS not configured on port \(port)"
                        ))
                    default:
                        break
                    }
                }

                connection.start(queue: queue)

                // Timeout after 2 seconds.
                queue.asyncAfter(deadline: .now() + 2) {
                    guard !resumed else { return }
                    resumed = true
                    connection.cancel()
                    continuation.resume(returning: CheckResult(
                        status: .fail,
                        message: "TLS not configured (connection timed out)"
                    ))
                }
            }
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
