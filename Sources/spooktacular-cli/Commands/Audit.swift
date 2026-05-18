import ArgumentParser
import Foundation
import SpooktacularKit

extension Spooktacular {

    /// Audit-trail inspection and verification commands.
    ///
    /// External auditors and operators use these to prove that a
    /// specific ``AuditRecord`` was committed to the tamper-evident
    /// log as of a signed tree head — the "show me the receipt"
    /// flow every SOC 2 / FedRAMP assessor asks for on day one.
    struct SpooktacularAudit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "audit",
            abstract: "Audit trail inspection and verification.",
            discussion: """
                EXAMPLES:
                  spook audit verify \\
                    --record record.json \\
                    --audit-path path.json \\
                    --tree-head sth.json \\
                    --public-key audit-public.pem
                """,
            subcommands: [
                SpooktacularAuditVerify.self,
            ]
        )

        // MARK: - verify

        /// Verifies a Merkle inclusion proof per RFC 6962 against a
        /// signed tree head.
        ///
        /// Exit codes:
        /// - `0` — proof verified and signature valid.
        /// - `1` — proof mismatch or signature invalid.
        /// - `2` — input error (missing file, malformed JSON).
        struct SpooktacularAuditVerify: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "verify",
                abstract: "Verify an RFC 6962 Merkle inclusion proof against a signed tree head."
            )

            @Option(name: .customLong("record"),
                    help: "Path to the audit record (JSON).")
            var recordPath: String

            @Option(name: .customLong("audit-path"),
                    help: "Path to the inclusion-proof document (JSON).")
            var auditPathPath: String

            @Option(name: .customLong("tree-head"),
                    help: "Path to the signed tree head (JSON).")
            var treeHeadPath: String

            @Option(name: .customLong("public-key"),
                    help: "Path to the Ed25519 public key (PEM).")
            var publicKeyPath: String

            func run() throws {
                let outcome: SignedTreeHeadVerifier.Outcome
                do {
                    outcome = try SignedTreeHeadVerifier.verify(
                        recordPath: recordPath,
                        auditPathPath: auditPathPath,
                        treeHeadPath: treeHeadPath,
                        publicKeyPath: publicKeyPath
                    )
                } catch let err as SignedTreeHeadVerifier.Error {
                    FileHandle.standardError.write(Data("\(err.description)\n".utf8))
                    throw ExitCode(2)
                } catch {
                    FileHandle.standardError.write(
                        Data("error: \(error.localizedDescription)\n".utf8)
                    )
                    throw ExitCode(2)
                }

                print("leaf hash:          \(outcome.leafHashHex)")
                print("reconstructed root: \(outcome.reconstructedRootHex)")
                print("tree-head root:     \(outcome.expectedRootHex)")
                print("signature:          \(outcome.signatureValid ? "valid" : "INVALID")")
                print("inclusion:          \(outcome.inclusionValid ? "valid" : "MISMATCH")")
                if outcome.signatureValid && outcome.inclusionValid {
                    print("VERIFIED")
                    return
                }
                print("FAILED")
                throw ExitCode(1)
            }
        }
    }
}
