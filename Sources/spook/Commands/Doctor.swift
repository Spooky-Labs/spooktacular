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

                EXAMPLES:
                  spook doctor
                """
        )

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

            // Summary
            print()
            let summary = "\(passed) passed, \(failed) failed, \(warned) warning"
                + (warned == 1 ? "" : "s")
            print(summary)

            if failed > 0 {
                throw ExitCode.failure
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
                let tlsParams = NWProtocolTLS.Options()
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
