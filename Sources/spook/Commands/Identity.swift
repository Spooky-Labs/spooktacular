import ArgumentParser
import CryptoKit
import Foundation
import SpooktacularKit

extension Spook {

    /// Manages SEP-bound signing identities: operator, host,
    /// OIDC issuer, Merkle audit.
    ///
    /// Thin wrapper around ``P256KeyStore``. Each subcommand
    /// operates on a single (service, label) pair so rotation
    /// and distribution are explicit.
    struct Identity: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "identity",
            abstract: "Manage SEP-bound signing keys (operator, host, OIDC, audit).",
            discussion: """
                Every purpose lives under its own Keychain service \
                so a reviewer can enumerate keys per concern:

                  operator   — sign API requests (presence-gated)
                  host       — sign host → guest-agent requests
                  oidc       — sign workload-identity JWTs
                  audit      — sign Merkle STHs

                `keygen` creates a new SEP-bound key.
                `show` prints the public key as PEM for distribution.
                `delete` removes the key (explicit rotation step).
                """,
            subcommands: [Keygen.self, Show.self, Delete.self]
        )

        struct Keygen: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Generate a SEP-bound P-256 signing key."
            )

            @Option(name: .customLong("type"),
                    help: "Key purpose: operator | host | oidc | audit.")
            var type: String

            @Option(name: .customLong("label"),
                    help: "Account label within the service namespace (e.g. alice-mbp, controller-prod-01).")
            var label: String

            @Option(name: .customLong("public-key"),
                    help: "Optional path to write the matching PEM SPKI public key.")
            var publicKeyPath: String?

            func run() async throws {
                let service = try resolveService(type: type)
                let presence = (type == "operator")

                if P256KeyStore.exists(service: service, label: label) {
                    print(Style.error("✗ Key already exists under service '\(service)' label '\(label)'."))
                    print(Style.dim("  Rotate explicitly: `spook identity delete --type \(type) --label \(label)` first."))
                    throw ExitCode.failure
                }

                do {
                    _ = try await P256KeyStore.loadOrCreateSEP(
                        service: service,
                        label: label,
                        presenceGated: presence,
                        authenticationPrompt: presence ? "Generate \(type) identity '\(label)'" : nil
                    )
                } catch let err as KeyStoreError {
                    print(Style.error("✗ \(err.localizedDescription)"))
                    if let hint = err.recoverySuggestion { print(Style.dim("  \(hint)")) }
                    throw ExitCode.failure
                }

                let pub = try P256KeyStore.publicKey(service: service, label: label)
                print(Style.success("✓ Hardware-bound \(type) identity generated."))
                print(Style.dim("  Service:     \(service)"))
                print(Style.dim("  Label:       \(label)"))
                print(Style.dim("  Presence:    \(presence ? "required per use (Touch ID / passcode)" : "none (daemon use)")"))
                if let out = publicKeyPath {
                    try writePublicKey(pub.pemRepresentation, to: out)
                    print(Style.dim("  Public key:  \(out)"))
                } else {
                    print("")
                    print(pub.pemRepresentation)
                }
            }
        }

        struct Show: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Print the PEM public key for an identity (no presence prompt)."
            )

            @Option(name: .customLong("type"),
                    help: "Key purpose: operator | host | oidc | audit.")
            var type: String

            @Option(name: .customLong("label"),
                    help: "Account label within the service namespace.")
            var label: String

            func run() async throws {
                let service = try resolveService(type: type)
                do {
                    let pub = try P256KeyStore.publicKey(service: service, label: label)
                    print(pub.pemRepresentation, terminator: "")
                } catch let err as KeyStoreError {
                    print(Style.error("✗ \(err.localizedDescription)"))
                    if let hint = err.recoverySuggestion { print(Style.dim("  \(hint)")) }
                    throw ExitCode.failure
                }
            }
        }

        struct Delete: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Remove an identity key from the Keychain."
            )

            @Option(name: .customLong("type"),
                    help: "Key purpose: operator | host | oidc | audit.")
            var type: String

            @Option(name: .customLong("label"),
                    help: "Account label within the service namespace.")
            var label: String

            func run() async throws {
                let service = try resolveService(type: type)
                do {
                    try P256KeyStore.delete(service: service, label: label)
                    print(Style.success("✓ Deleted \(type) identity '\(label)'."))
                } catch let err as KeyStoreError {
                    print(Style.error("✗ \(err.localizedDescription)"))
                    throw ExitCode.failure
                }
            }
        }
    }
}

/// Maps the user-facing `--type` to a Keychain service string.
private func resolveService(type: String) throws -> String {
    switch type {
    case "operator":  return P256KeyStore.Service.operatorIdentity
    case "host":      return P256KeyStore.Service.hostIdentity
    case "oidc":      return P256KeyStore.Service.oidcIssuer
    case "audit":     return P256KeyStore.Service.merkleAudit
    case "break-glass":
        return P256KeyStore.Service.breakGlass
    default:
        print(Style.error("✗ Unknown identity type '\(type)'. Use one of: operator, host, oidc, audit, break-glass."))
        throw ExitCode.failure
    }
}

/// Atomically writes a PEM file at mode 0644 (public keys are
/// not secrets, but refusing to overwrite prevents stale key
/// distribution).
private func writePublicKey(_ pem: String, to path: String) throws {
    if FileManager.default.fileExists(atPath: path) {
        print(Style.error("✗ Public-key file already exists at \(path) — refusing to overwrite."))
        throw ExitCode.failure
    }
    try Data(pem.utf8).write(to: URL(filePath: path), options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o644 as NSNumber], ofItemAtPath: path
    )
}
