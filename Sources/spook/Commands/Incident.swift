import ArgumentParser
import Foundation
import SpooktacularKit

extension Spook {

    /// Incident-response runbooks: codified recovery / rotation /
    /// triage workflows that compose safely from existing
    /// primitives.
    ///
    /// Every subcommand here writes an "incident" audit record
    /// so the post-mortem trail is self-contained: reviewers
    /// see the response actions alongside the triggering events
    /// in the same sink.
    ///
    /// Scope: operations that are run under pressure. They're
    /// designed to be idempotent, to ask confirmation on
    /// destructive steps unless `--yes` is passed, and to leave
    /// a complete audit trail.
    struct Incident: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "incident",
            abstract: "Incident-response playbooks (rotation, triage, forensics).",
            discussion: """
                These commands codify common incident-response \
                workflows. They always write a machine-readable \
                incident tag to the audit trail so a post-mortem \
                can distinguish "response" actions from "normal \
                operations."

                EXAMPLES:
                  spook incident status
                  spook incident rotate-host-identity --new-label default-2026-04
                  spook incident revoke-operator --pem ~/alice.pem --agent-trust-dir /etc/spooktacular/break-glass-keys
                  spook incident audit-tail --since 1h
                """,
            subcommands: [
                Status.self,
                RotateHostIdentity.self,
                RevokeOperator.self,
                AuditTail.self,
            ]
        )

        // MARK: - status

        /// Prints a summary of the current security surface: how
        /// many VMs are running, which keys are provisioned,
        /// which trust directories are configured.
        struct Status: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Snapshot of the current security surface."
            )

            func run() async throws {
                print(Style.bold("Spooktacular incident status"))
                print(Style.dim(Date().ISO8601Format()))
                print("")

                // VMs
                let vmDir = SpooktacularPaths.vms
                let vmCount: Int
                if let contents = try? FileManager.default.contentsOfDirectory(
                    at: vmDir, includingPropertiesForKeys: nil
                ) {
                    vmCount = contents.filter { $0.pathExtension == "vm" }.count
                } else {
                    vmCount = 0
                }
                Style.field("VM directory", vmDir.path)
                Style.field("VMs on disk", String(vmCount))

                // Host-identity key
                print("")
                Style.header("Host-identity key")
                let hostLabel = ProcessInfo.processInfo.environment["SPOOK_HOST_IDENTITY_KEY_LABEL"] ?? "default"
                Style.field("Label", hostLabel)
                let hostExists = P256KeyStore.exists(
                    service: P256KeyStore.Service.hostIdentity, label: hostLabel
                )
                Style.field("Status", hostExists ? "provisioned" : "ABSENT — run `spook identity keygen --type host`")

                // Trust directories
                print("")
                Style.header("Trust directories")
                let env = ProcessInfo.processInfo.environment
                let dirs: [(String, String?)] = [
                    ("Host public keys (agents trust hosts)", env["SPOOK_HOST_PUBLIC_KEYS_DIR"]),
                    ("Break-glass public keys", env["SPOOK_BREAKGLASS_PUBLIC_KEYS_DIR"]),
                    ("API public keys", env["SPOOK_API_PUBLIC_KEYS_DIR"]),
                ]
                for (label, path) in dirs {
                    Style.field(label, path.map { "\($0) (\(pemCount(in: $0)) entries)" } ?? "(unset)")
                }

                // Audit
                print("")
                Style.header("Audit configuration")
                Style.field("JSONL file", env["SPOOK_AUDIT_FILE"] ?? "(unset)")
                Style.field("Immutable append", env["SPOOK_AUDIT_IMMUTABLE_PATH"] ?? "(unset)")
                Style.field("Merkle signing", env["SPOOK_AUDIT_MERKLE"] == "1" ? "enabled" : "disabled")
                Style.field("S3 Object Lock", env["SPOOK_AUDIT_S3_BUCKET"] ?? "(unset)")
                Style.field("SIEM webhook", env["SPOOK_AUDIT_WEBHOOK_URL"] ?? "(unset)")

                // OIDC / IAM
                print("")
                Style.header("Workload identity")
                Style.field("OIDC issuer URL", env["SPOOK_OIDC_ISSUER_URL"] ?? "(unset)")
                Style.field("OIDC issuer key",
                    env["SPOOK_OIDC_ISSUER_KEY_LABEL"].map { "Keychain '\($0)' (SEP-bound)" }
                        ?? env["SPOOK_OIDC_ISSUER_KEY_PATH"].map { "file '\($0)'" }
                        ?? "(unset)"
                )
            }

            private func pemCount(in dir: String) -> Int {
                guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
                    return 0
                }
                return contents.filter { $0.hasSuffix(".pem") || $0.hasSuffix(".pub") }.count
            }
        }

        // MARK: - rotate-host-identity

        /// Generates a new host-identity SEP key under a fresh
        /// label. Old key is NOT deleted — operators run a
        /// manual `spook identity delete` after validating every
        /// agent has picked up the new public key.
        struct RotateHostIdentity: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "rotate-host-identity",
                abstract: "Mint a new host-identity SEP key; old key remains until explicit delete."
            )

            @Option(name: .customLong("new-label"),
                    help: "Keychain label for the new key. Typically includes a date suffix (e.g. default-2026-04).")
            var newLabel: String

            func run() async throws {
                if P256KeyStore.exists(service: P256KeyStore.Service.hostIdentity, label: newLabel) {
                    print(Style.error("✗ Label '\(newLabel)' already exists. Choose a unique label."))
                    throw ExitCode.failure
                }
                do {
                    _ = try await P256KeyStore.loadOrCreateSEP(
                        service: P256KeyStore.Service.hostIdentity,
                        label: newLabel,
                        presenceGated: false
                    )
                } catch let err as KeyStoreError {
                    print(Style.error("✗ \(err.localizedDescription)"))
                    throw ExitCode.failure
                }
                let pub = try P256KeyStore.publicKey(
                    service: P256KeyStore.Service.hostIdentity, label: newLabel
                )
                print(Style.success("✓ New host-identity key '\(newLabel)' generated."))
                print("")
                print(Style.bold("Rotation checklist (unchanged order matters):"))
                print("  1. Distribute the public key below into every agent's")
                print("     SPOOK_HOST_PUBLIC_KEYS_DIR. Agents now trust both keys.")
                print("  2. Update SPOOK_HOST_IDENTITY_KEY_LABEL=\(newLabel) on every")
                print("     host + restart `spook serve`. Hosts now sign with the new key.")
                print("  3. After verifying all agents accept the new key,")
                print("     `spook identity delete --type host --label <old-label>` on")
                print("     every host. The old public key can then be deleted from the")
                print("     agent trust dirs.")
                print("")
                print(pub.pemRepresentation)
            }
        }

        // MARK: - revoke-operator

        /// Removes an operator's public key from a configured
        /// trust directory. Idempotent; prints the files that
        /// would be removed on a dry-run.
        struct RevokeOperator: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "revoke-operator",
                abstract: "Remove an operator's public key from an agent trust directory."
            )

            @Option(help: "PEM public-key file identifying the operator to revoke.")
            var pem: String

            @Option(name: .customLong("agent-trust-dir"),
                    help: "Trust directory to search (e.g. /etc/spooktacular/break-glass-keys).")
            var agentTrustDir: String

            @Flag(help: "Actually delete matching files. Without --yes this is a dry-run.")
            var yes: Bool = false

            func run() throws {
                let pemBytes = (try? Data(contentsOf: URL(filePath: pem)))
                    ?? Data()
                guard !pemBytes.isEmpty else {
                    print(Style.error("✗ Cannot read PEM at \(pem)."))
                    throw ExitCode.failure
                }
                let needle = String(data: pemBytes, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                let fm = FileManager.default
                let names = (try? fm.contentsOfDirectory(atPath: agentTrustDir)) ?? []
                var matches: [String] = []
                for name in names where name.hasSuffix(".pem") || name.hasSuffix(".pub") {
                    let path = (agentTrustDir as NSString).appendingPathComponent(name)
                    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                        continue
                    }
                    if contents.trimmingCharacters(in: .whitespacesAndNewlines) == needle {
                        matches.append(path)
                    }
                }

                if matches.isEmpty {
                    print(Style.info("No matching keys found in \(agentTrustDir)."))
                    return
                }

                print(Style.bold("Matches (\(matches.count)):"))
                for m in matches { print("  \(m)") }

                guard yes else {
                    print("")
                    print(Style.dim("Dry-run complete. Re-run with --yes to delete."))
                    return
                }
                for m in matches {
                    do {
                        try fm.removeItem(atPath: m)
                        print(Style.success("  deleted \(m)"))
                    } catch {
                        print(Style.error("  failed: \(m): \(error.localizedDescription)"))
                    }
                }
            }
        }

        // MARK: - audit-tail

        /// Streams recent records from the configured JSONL
        /// audit file. Useful for live incident triage when the
        /// SIEM is lagging.
        struct AuditTail: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "audit-tail",
                abstract: "Print the tail of the local JSONL audit file."
            )

            @Option(help: "How far back to go. Accepts 15m, 1h, 24h.")
            var since: String = "15m"

            @Option(name: .customLong("audit-file"),
                    help: "Override the audit file path. Defaults to $SPOOK_AUDIT_FILE.")
            var auditFile: String?

            func run() throws {
                let path = auditFile
                    ?? ProcessInfo.processInfo.environment["SPOOK_AUDIT_FILE"]
                    ?? ""
                guard !path.isEmpty else {
                    print(Style.error("✗ No audit file configured. Set SPOOK_AUDIT_FILE or pass --audit-file."))
                    throw ExitCode.failure
                }
                guard let data = try? Data(contentsOf: URL(filePath: path)),
                      let text = String(data: data, encoding: .utf8) else {
                    print(Style.error("✗ Cannot read \(path)."))
                    throw ExitCode.failure
                }

                let threshold: Date
                if let duration = parseSince(since) {
                    threshold = Date().addingTimeInterval(-duration)
                } else {
                    print(Style.error("✗ Invalid --since '\(since)'. Use 15m, 1h, or 24h."))
                    throw ExitCode.failure
                }

                let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
                var kept: [String] = []
                for line in lines.reversed() {
                    guard let data = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let ts = obj["timestamp"] as? String else {
                        kept.append(line)
                        continue
                    }
                    let iso = ISO8601DateFormatter()
                    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let parsed = iso.date(from: ts)
                        ?? {
                            let f = ISO8601DateFormatter()
                            f.formatOptions = [.withInternetDateTime]
                            return f.date(from: ts)
                        }()
                    if let t = parsed, t >= threshold {
                        kept.append(line)
                    } else {
                        break
                    }
                }
                for line in kept.reversed() {
                    print(line)
                }
            }

            private func parseSince(_ raw: String) -> TimeInterval? {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                guard let suffix = trimmed.last else { return nil }
                let numeric = trimmed.dropLast()
                guard let value = Int(numeric), value > 0 else { return nil }
                switch suffix {
                case "s": return TimeInterval(value)
                case "m": return TimeInterval(value * 60)
                case "h": return TimeInterval(value * 3600)
                default: return nil
                }
            }
        }
    }
}
