import ArgumentParser
import CryptoKit
import Foundation
import SpooktacularKit

extension Spook {

    /// Break-glass ticket management for emergency guest-agent
    /// access.
    ///
    /// Break-glass is the emergency-access pattern documented in
    /// NIST SP 800-53 AC-14, OWASP ASVS V2.10, and SOC 2 CC6.6.
    /// Spooktacular signs tickets with P-256 ECDSA using keys
    /// bound to the macOS Secure Enclave (per-operator, AAL3) and
    /// enforces single-use at the guest agent via a JTI denylist.
    /// See `SECURITY.md §Break-glass` for the threat model and
    /// `docs/OWASP_ASVS_AUDIT.md §V2.7` for control mapping.
    struct BreakGlass: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "break-glass",
            abstract: "Issue and manage emergency-access tickets.",
            subcommands: [Keygen.self, Issue.self],
            defaultSubcommand: Issue.self
        )

        // MARK: - keygen

        /// Generates a P-256 key pair for break-glass signing.
        ///
        /// Two modes:
        ///
        /// - **Hardware-bound (recommended):** pass
        ///   `--keychain-label <label>`. The private key is
        ///   generated **inside** the Secure Enclave and never
        ///   leaves it. Signing requires Touch ID / passcode
        ///   at use time. AAL3 per NIST SP 800-63B.
        /// - **Software (CI / headless hosts only):** pass
        ///   `--private-key <path>`. A P-256 software key is
        ///   written as PEM. Weaker, but sometimes necessary.
        ///
        /// In either mode the public key is exported as PEM SPKI
        /// to `--public-key`. Add that PEM file to each agent's
        /// `SPOOK_BREAKGLASS_PUBLIC_KEYS_DIR` to trust the
        /// operator who holds the private key.
        struct Keygen: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "keygen",
                abstract: "Generate a P-256 key pair for signing break-glass tickets.",
                discussion: """
                    Preferred (hardware-bound, per-operator): \
                    generate inside the Secure Enclave with \
                    --keychain-label. The resulting key cannot \
                    leave this Mac and requires Touch ID / passcode \
                    per-signature.

                    Fallback (software, for CI / non-Apple-Silicon \
                    hosts): --private-key writes a PEM-encoded P-256 \
                    key to disk at mode 0600.

                    In both modes --public-key receives the PEM SPKI \
                    public key; distribute that file to every guest \
                    agent's SPOOK_BREAKGLASS_PUBLIC_KEYS_DIR.

                    EXAMPLES:
                      spook break-glass keygen \\
                        --keychain-label alice-mbp \\
                        --public-key  ~/alice-break-glass.pem

                      spook break-glass keygen \\
                        --private-key /etc/spooktacular/secrets/bg-signing.pem \\
                        --public-key  /etc/spooktacular/bg-signing.pub
                    """
            )

            @Option(name: .customLong("private-key"),
                    help: "Destination path for a PEM-encoded P-256 private key (mode 0600). Mutually exclusive with --keychain-label. Prefer the Keychain path; use this only when no Secure Enclave is available.")
            var privateKeyPath: String?

            @Option(name: .customLong("public-key"),
                    help: "Destination path for the matching PEM-encoded P-256 public key (SPKI).")
            var publicKeyPath: String

            @Option(name: .customLong("keychain-label"),
                    help: "Generate the private key inside the Secure Enclave under this Keychain label. Signing requires Touch ID / passcode (OWASP ASVS V2.7 / V4.3.1; AAL3).")
            var keychainLabel: String?

            func run() async throws {
                guard privateKeyPath != nil || keychainLabel != nil else {
                    print(Style.error("✗ Provide either --private-key <path> or --keychain-label <label>."))
                    print(Style.dim("  --keychain-label is the recommended mode on Apple Silicon workstations."))
                    throw ExitCode.failure
                }
                if privateKeyPath != nil && keychainLabel != nil {
                    print(Style.error("✗ --private-key and --keychain-label are mutually exclusive."))
                    throw ExitCode.failure
                }

                let publicKeyPEM: String

                if let label = keychainLabel {
                    if P256KeyStore.exists(service: P256KeyStore.Service.breakGlass, label: label) {
                        print(Style.error("✗ A break-glass key already exists under label '\(label)'."))
                        print(Style.dim("  Delete it explicitly before rotating."))
                        throw ExitCode.failure
                    }
                    do {
                        _ = try await P256KeyStore.loadOrCreateSEP(
                            service: P256KeyStore.Service.breakGlass,
                            label: label,
                            presenceGated: true,
                            authenticationPrompt: "Generate break-glass signing key '\(label)'"
                        )
                        let pub = try P256KeyStore.publicKey(
                            service: P256KeyStore.Service.breakGlass, label: label
                        )
                        publicKeyPEM = pub.pemRepresentation
                    } catch let err as KeyStoreError {
                        print(Style.error("✗ \(err.localizedDescription)"))
                        if let hint = err.recoverySuggestion { print(Style.dim("  \(hint)")) }
                        throw ExitCode.failure
                    }
                    print(Style.success("✓ Hardware-bound key pair generated."))
                    print(Style.dim("  Private: Secure Enclave (Keychain label '\(label)', non-exportable)"))
                } else {
                    let path = privateKeyPath!
                    let priv = P256.Signing.PrivateKey()
                    try writePEM(
                        priv.pemRepresentation,
                        to: path,
                        mode: 0o600,
                        label: "Private key"
                    )
                    publicKeyPEM = priv.publicKey.pemRepresentation
                    print(Style.success("✓ Software key pair generated."))
                    print(Style.dim("  Private: \(path) (keep this secret — HSM or sealed envelope)"))
                }

                try writePEM(
                    publicKeyPEM,
                    to: publicKeyPath,
                    mode: 0o644,
                    label: "Public key"
                )
                print(Style.dim("  Public:  \(publicKeyPath) (distribute into each agent's SPOOK_BREAKGLASS_PUBLIC_KEYS_DIR)"))
            }

            /// Atomically creates a file with strict permissions.
            ///
            /// `open(2)` with `O_CREAT | O_EXCL | O_NOFOLLOW` and
            /// `mode 0600` closes the umask-default TOCTOU window
            /// a `Data.write(.atomic)` + `setAttributes` sequence
            /// would leave open.
            private func writePEM(
                _ text: String,
                to path: String,
                mode: mode_t,
                label: String
            ) throws {
                let dir = URL(filePath: path).deletingLastPathComponent()
                try? FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: path) {
                    print(Style.error("✗ \(label) file already exists at \(path) — refusing to overwrite."))
                    print(Style.dim("  Remove it explicitly if you intend to rotate."))
                    throw ExitCode.failure
                }
                let data = Data(text.utf8)
                try path.withCString { cPath in
                    let fd = open(cPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
                    guard fd >= 0 else {
                        print(Style.error("✗ Cannot create \(label) at \(path): errno \(errno)"))
                        throw ExitCode.failure
                    }
                    defer { close(fd) }
                    try data.withUnsafeBytes { buffer in
                        var remaining = buffer.count
                        var base = buffer.baseAddress
                        while remaining > 0 {
                            let written = write(fd, base, remaining)
                            if written < 0 {
                                if errno == EINTR { continue }
                                print(Style.error("✗ Write to \(label) failed: errno \(errno)"))
                                throw ExitCode.failure
                            }
                            remaining -= written
                            base = base?.advanced(by: written)
                        }
                    }
                    fsync(fd)
                }
            }
        }

        // MARK: - issue

        /// Mints a signed break-glass ticket.
        struct Issue: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "issue",
                abstract: "Mint a time-limited, single-use break-glass ticket.",
                discussion: """
                    Signs a P-256 ECDSA break-glass ticket and prints \
                    it to stdout. The ticket is ONE-TIME by default \
                    — use --uses to issue a multi-use ticket for a \
                    single debugging session that needs multiple API \
                    calls.

                    TTL is capped at 1 hour by policy (OWASP \
                    Short-Lived Credentials). For incidents expected \
                    to run longer, re-issue periodically so each \
                    window is independently audited.

                    --keychain-label (recommended): loads the SEP- \
                    bound key for the given label and signs inside \
                    the Secure Enclave — Touch ID / passcode required.

                    --signing-key: loads a PEM-encoded software key \
                    from disk. Use only when no Secure Enclave is \
                    available.

                    EXAMPLES:
                      spook break-glass issue \\
                        --tenant acme \\
                        --issuer alice@acme \\
                        --ttl 15m \\
                        --keychain-label alice-mbp \\
                        --reason "runner-17 stuck in draining"
                    """
            )

            @Option(help: "Tenant this ticket scopes access to.")
            var tenant: String

            @Option(help: "Operator identity requesting the ticket (audit attribution).")
            var issuer: String

            @Option(name: .customLong("ttl"),
                    help: "Ticket lifetime. Accepts `15m`, `1h`, or an integer count of seconds. Capped at 1h.")
            var ttl: String = "15m"

            @Option(help: "Maximum number of uses for this ticket (default 1 = strict single-use).")
            var uses: Int = 1

            @Option(name: .customLong("signing-key"),
                    help: "Path to a PEM-encoded P-256 private key file. Mutually exclusive with --keychain-label.")
            var signingKeyPath: String?

            @Option(name: .customLong("keychain-label"),
                    help: "Load the SEP-bound signing key from the macOS Keychain under this label. Prompts for Touch ID / passcode (OWASP ASVS V2.7 per-action MFA).")
            var keychainLabel: String?

            @Option(help: "Human-readable reason surfaced in every audit record. Strongly recommended.")
            var reason: String?

            func run() async throws {
                guard signingKeyPath != nil || keychainLabel != nil else {
                    print(Style.error("✗ Provide either --signing-key <path> or --keychain-label <label>."))
                    throw ExitCode.failure
                }
                if signingKeyPath != nil && keychainLabel != nil {
                    print(Style.error("✗ --signing-key and --keychain-label are mutually exclusive."))
                    throw ExitCode.failure
                }

                // In file-path mode the SEP isn't involved, so
                // we still want per-action MFA on the CLI command
                // itself — close the "compromised shell reads
                // an operator's PEM file" loop.
                if signingKeyPath != nil {
                    _ = try await AdminPresenceGate.requirePresence(
                        reason: "Mint a break-glass ticket for tenant '\(tenant)'"
                    )
                }

                // Parse TTL.
                let ttlSeconds: TimeInterval
                do {
                    ttlSeconds = try Self.parseTTL(ttl)
                } catch {
                    print(Style.error("✗ Invalid --ttl: \(ttl). Use `15m`, `1h`, or an integer count of seconds."))
                    throw ExitCode.failure
                }

                // Build the signer.
                let signer: any BreakGlassSigner
                if let path = signingKeyPath {
                    do {
                        let pem = try String(contentsOfFile: path, encoding: .utf8)
                        signer = try P256.Signing.PrivateKey(pemRepresentation: pem)
                    } catch {
                        print(Style.error("✗ Cannot read signing key at \(path): \(error.localizedDescription)"))
                        print(Style.dim("  Generate one with `spook break-glass keygen` first."))
                        throw ExitCode.failure
                    }
                } else {
                    let label = keychainLabel!
                    do {
                        signer = try await P256KeyStore.loadOrCreateSEP(
                            service: P256KeyStore.Service.breakGlass,
                            label: label,
                            presenceGated: true,
                            authenticationPrompt: "Mint a break-glass ticket for tenant '\(tenant)'" + (reason.map { " — \($0)" } ?? "")
                        )
                    } catch let err as KeyStoreError {
                        print(Style.error("✗ \(err.localizedDescription)"))
                        if let hint = err.recoverySuggestion { print(Style.dim("  \(hint)")) }
                        throw ExitCode.failure
                    }
                }

                let now = Date()
                let ticket = BreakGlassTicket(
                    jti: UUID().uuidString,
                    issuer: issuer,
                    tenant: TenantID(tenant),
                    issuedAt: now,
                    expiresAt: now.addingTimeInterval(ttlSeconds),
                    maxUses: uses,
                    reason: reason
                )

                let wire: String
                do {
                    wire = try BreakGlassTicketCodec.encode(ticket, signer: signer)
                } catch let err as BreakGlassTicketError {
                    print(Style.error("✗ \(err.localizedDescription)"))
                    if let hint = err.recoverySuggestion {
                        print(Style.dim("  \(hint)"))
                    }
                    throw ExitCode.failure
                }

                // Audit the issuance locally so every minted
                // ticket leaves a trace on the operator's machine
                // even if the ticket itself is never consumed.
                Log.audit.notice(
                    "Break-glass ticket issued: jti=\(ticket.jti, privacy: .public) tenant=\(tenant, privacy: .public) issuer=\(self.issuer, privacy: .public) ttl=\(Int(ttlSeconds))s uses=\(uses) reason=\(self.reason ?? "(none)", privacy: .public)"
                )

                // Ticket to stdout, nothing else — pipeable into
                // an HTTP header or a secret manager.
                print(wire)
            }

            /// Parses `15m`, `1h`, or an integer count of seconds.
            private static func parseTTL(_ raw: String) throws -> TimeInterval {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if let seconds = Int(trimmed) {
                    return TimeInterval(seconds)
                }
                let suffix = trimmed.last.map(String.init) ?? ""
                let numeric = String(trimmed.dropLast())
                guard let value = Int(numeric), value > 0 else {
                    throw CocoaError(.formatting)
                }
                switch suffix {
                case "s": return TimeInterval(value)
                case "m": return TimeInterval(value * 60)
                case "h": return TimeInterval(value * 3600)
                default: throw CocoaError(.formatting)
                }
            }
        }
    }
}
