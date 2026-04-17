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
    /// Spooktacular's implementation signs tickets with Ed25519
    /// (RFC 8037) and enforces single-use at the guest agent via
    /// an in-memory JTI denylist. See `SECURITY.md §Break-glass`
    /// for the full threat model and the OWASP JWT Cheat Sheet
    /// cross-reference.
    struct BreakGlass: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "break-glass",
            abstract: "Issue and manage emergency-access tickets.",
            subcommands: [Keygen.self, Issue.self],
            defaultSubcommand: Issue.self
        )

        // MARK: - keygen

        /// Generates a fresh Ed25519 key pair for break-glass
        /// signing. Intended to be run once per fleet — after
        /// that the private key is held by the on-call SRE team
        /// (or a hardware key) and the public key is distributed
        /// to every guest agent via `SPOOK_BREAKGLASS_PUBLIC_KEY`.
        struct Keygen: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "keygen",
                abstract: "Generate an Ed25519 key pair for signing break-glass tickets.",
                discussion: """
                    Writes the private key to the path given by \
                    --private-key (owner-only, mode 0600) and the \
                    public key to --public-key (mode 0644). \
                    Distribute the public key to every guest agent \
                    via SPOOK_BREAKGLASS_PUBLIC_KEY; keep the \
                    private key in a hardware security module or \
                    a sealed envelope per your incident-response \
                    runbook.

                    EXAMPLES:
                      spook break-glass keygen \\
                        --private-key /etc/spooktacular/secrets/bg-signing.key \\
                        --public-key  /etc/spooktacular/bg-signing.pub
                    """
            )

            @Option(name: .customLong("private-key"),
                    help: "Destination path for the Ed25519 private key (mode 0600). Mutually exclusive with --keychain-label.")
            var privateKeyPath: String?

            @Option(name: .customLong("public-key"),
                    help: "Destination path for the matching public key (mode 0644).")
            var publicKeyPath: String

            @Option(name: .customLong("keychain-label"),
                    help: "Store the private key in the macOS Keychain with user-presence (Touch ID / passcode) required at retrieval. Satisfies OWASP ASVS V2.7.")
            var keychainLabel: String?

            func run() async throws {
                guard privateKeyPath != nil || keychainLabel != nil else {
                    print(Style.error("✗ Provide either --private-key <path> or --keychain-label <label>."))
                    print(Style.dim("  --keychain-label is the recommended mode on workstations with Touch ID."))
                    throw ExitCode.failure
                }
                if privateKeyPath != nil && keychainLabel != nil {
                    print(Style.error("✗ --private-key and --keychain-label are mutually exclusive."))
                    throw ExitCode.failure
                }

                let key = Curve25519.Signing.PrivateKey()

                if let path = privateKeyPath {
                    try writeSecret(
                        key.rawRepresentation,
                        to: path,
                        mode: 0o600,
                        label: "Private key"
                    )
                    print(Style.success("✓ Key pair written."))
                    print(Style.dim("  Private: \(path) (keep this secret — HSM or sealed envelope)"))
                }

                if let label = keychainLabel {
                    do {
                        try BreakGlassSigningKeyStore.store(key, label: label)
                    } catch let err as BreakGlassSigningKeyStoreError {
                        print(Style.error("✗ \(err.localizedDescription)"))
                        if let hint = err.recoverySuggestion { print(Style.dim("  \(hint)")) }
                        throw ExitCode.failure
                    }
                    print(Style.success("✓ Key pair written."))
                    print(Style.dim("  Private: macOS Keychain (label '\(label)', requires Touch ID / passcode at retrieval)"))
                }

                try writeSecret(
                    key.publicKey.rawRepresentation,
                    to: publicKeyPath,
                    mode: 0o644,
                    label: "Public key"
                )
                print(Style.dim("  Public:  \(publicKeyPath) (distribute to agents via SPOOK_BREAKGLASS_PUBLIC_KEY)"))
            }

            /// Atomically creates a key file with strict permissions.
            ///
            /// `open(2)` with `O_CREAT | O_EXCL | O_NOFOLLOW` and
            /// `mode 0600` is the only way to close the
            /// umask-default TOCTOU window — a `Data.write(.atomic)`
            /// followed by `setAttributes` would leave a tmp file
            /// readable by any other local user for the write-then-
            /// chmod window.
            private func writeSecret(
                _ data: Data,
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
        ///
        /// The operator runs this during an incident; the
        /// resulting `bgt:...` string is the ONE-TIME credential
        /// that grants break-glass tier access to the named
        /// tenant's guest agent. Each invocation audits the
        /// issuance locally via OSLog.
        struct Issue: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "issue",
                abstract: "Mint a time-limited, single-use break-glass ticket.",
                discussion: """
                    Signs an Ed25519-based break-glass ticket and \
                    prints it to stdout. The ticket is ONE-TIME \
                    by default — use --uses to issue a multi-use \
                    ticket for a single debugging session that \
                    needs multiple API calls.

                    TTL is capped at 1 hour by policy (OWASP \
                    Short-Lived Credentials). For incidents \
                    expected to run longer, re-issue periodically \
                    so each window is independently audited.

                    EXAMPLES:
                      spook break-glass issue \\
                        --tenant acme \\
                        --issuer alice@acme \\
                        --ttl 15m \\
                        --signing-key /etc/spooktacular/secrets/bg-signing.key \\
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
                    help: "Path to the Ed25519 private key file (raw 32-byte representation). Mutually exclusive with --keychain-label.")
            var signingKeyPath: String?

            @Option(name: .customLong("keychain-label"),
                    help: "Load the signing key from the macOS Keychain. Prompts for Touch ID / passcode (OWASP ASVS V2.7 per-action MFA).")
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

                // Per-action MFA (OWASP ASVS V2.7 / V4.3.1).
                // Keychain mode triggers Touch ID at key retrieval,
                // so the presence gate is redundant there — we only
                // invoke it for file-path mode to close the
                // compromised-shell scenario for that path too.
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

                // Load the signing key.
                let key: Curve25519.Signing.PrivateKey
                if let path = signingKeyPath {
                    do {
                        let raw = try Data(contentsOf: URL(filePath: path))
                        key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
                    } catch {
                        print(Style.error("✗ Cannot read signing key at \(path): \(error.localizedDescription)"))
                        print(Style.dim("  Generate one with `spook break-glass keygen` first."))
                        throw ExitCode.failure
                    }
                } else {
                    let label = keychainLabel!
                    do {
                        key = try BreakGlassSigningKeyStore.load(
                            label: label,
                            reason: "Mint a break-glass ticket for tenant '\(tenant)'" + (reason.map { " — \($0)" } ?? "")
                        )
                    } catch let err as BreakGlassSigningKeyStoreError {
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
                    wire = try BreakGlassTicketCodec.encode(ticket, signingKey: key)
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
