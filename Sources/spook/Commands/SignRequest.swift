import ArgumentParser
import CryptoKit
import Foundation
import SpooktacularKit

extension Spook {

    /// Signs an HTTP request with the caller's P-256 key and
    /// emits the three `X-Spook-*` headers for `curl` / any
    /// client to forward.
    ///
    /// Replaces the now-retired `Authorization: Bearer <token>`
    /// pattern on the Spooktacular API. The server (`spook serve`)
    /// verifies every request via its trusted-keys allowlist; this
    /// subcommand is the ergonomic operator-side path for scripts,
    /// monitoring probes, and third-party integrations that need
    /// to talk to the API without writing their own signer.
    ///
    /// ## Example
    ///
    /// ```bash
    /// # Operator workstation (one-time):
    /// spook break-glass keygen \
    ///     --keychain-label alice-api \
    ///     --public-key ~/alice-api.pem
    /// # Deploy alice-api.pem into the server's
    /// # SPOOK_API_PUBLIC_KEYS_DIR as alice@acme.pem.
    ///
    /// # Later, call the API:
    /// spook sign-request GET /v1/vms \
    ///     --keychain-label alice-api \
    ///     --curl-args | xargs curl https://spook.acme:8484
    /// ```
    ///
    /// The subcommand re-uses the break-glass signing-key store —
    /// operators who already have a Keychain-backed SEP key for
    /// emergency access can use the same `--keychain-label` here.
    /// Separate keys per purpose are also supported; the signing
    /// primitive is the same either way.
    struct SignRequest: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sign-request",
            abstract: "Sign an HTTP request and emit X-Spook-* headers for curl / clients.",
            discussion: """
                Canonical form signed over:
                  <METHOD>\\n<path>\\n<sha256-hex(body)>\\n<ts>\\n<nonce>

                By default emits one `Name: Value` header per line. \
                Pass --curl-args to emit `-H "Name: Value"` pairs \
                suitable for `xargs curl`.

                Body bytes are read from stdin by default; use \
                --body-file <path> to read from a file or --empty \
                to sign over an empty body.

                EXAMPLES:
                  # Simple GET (no body):
                  spook sign-request GET /v1/vms \\
                    --keychain-label alice-api --empty

                  # POST with a JSON body from stdin:
                  echo '{"name":"runner-01"}' | \\
                    spook sign-request POST /v1/vms/runner-01/clone \\
                    --keychain-label alice-api \\
                    --curl-args \\
                    | xargs curl -X POST -d @- \\
                      --data-binary @- https://spook.acme:8484
                """
        )

        @Argument(help: "HTTP method (GET, POST, DELETE, etc.).")
        var method: String

        @Argument(help: "Request path including query string.")
        var path: String

        @Option(name: .customLong("keychain-label"),
                help: "Load the signing key from the macOS Keychain (SEP-bound). Prompts for Touch ID / passcode.")
        var keychainLabel: String?

        @Option(name: .customLong("signing-key"),
                help: "Path to a PEM-encoded P-256 private key file. Mutually exclusive with --keychain-label.")
        var signingKeyPath: String?

        @Option(name: .customLong("body-file"),
                help: "Read the request body from this file instead of stdin.")
        var bodyFile: String?

        @Flag(name: .customLong("empty"),
              help: "Sign over an empty body (skip stdin read).")
        var emptyBody: Bool = false

        @Flag(name: .customLong("curl-args"),
              help: "Emit `-H \"Name: Value\"` pairs instead of raw headers, suitable for xargs curl.")
        var curlArgs: Bool = false

        func run() async throws {
            guard signingKeyPath != nil || keychainLabel != nil else {
                print(Style.error("✗ Provide either --signing-key <path> or --keychain-label <label>."))
                throw ExitCode.failure
            }
            if signingKeyPath != nil && keychainLabel != nil {
                print(Style.error("✗ --signing-key and --keychain-label are mutually exclusive."))
                throw ExitCode.failure
            }

            // Read body bytes.
            let body: Data
            if emptyBody {
                body = Data()
            } else if let path = bodyFile {
                body = (try? Data(contentsOf: URL(filePath: path))) ?? Data()
            } else {
                body = FileHandle.standardInput.readDataToEndOfFile()
            }

            // Load signer.
            let signer: any P256Signer
            if let path = signingKeyPath {
                do {
                    let pem = try String(contentsOfFile: path, encoding: .utf8)
                    signer = try P256.Signing.PrivateKey(pemRepresentation: pem)
                } catch {
                    print(Style.error("✗ Cannot read signing key at \(path): \(error.localizedDescription)"))
                    throw ExitCode.failure
                }
            } else {
                let label = keychainLabel!
                do {
                    signer = try await BreakGlassSigningKeyStore.loadSigner(
                        label: label,
                        reason: "Sign API request: \(method) \(self.path)"
                    )
                } catch let err as BreakGlassSigningKeyStoreError {
                    print(Style.error("✗ \(err.localizedDescription)"))
                    if let hint = err.recoverySuggestion { print(Style.dim("  \(hint)")) }
                    throw ExitCode.failure
                }
            }

            // Build canonical string + sign.
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            let timestamp = iso.string(from: Date())
            let nonce = UUID().uuidString
            let bodyHash = SignedRequestVerifier.hexSHA256(body)
            let canonical = "\(method.uppercased())\n\(self.path)\n\(bodyHash)\n\(timestamp)\n\(nonce)"

            let signatureRaw: Data
            do {
                signatureRaw = try signer.signature(for: Data(canonical.utf8))
            } catch {
                print(Style.error("✗ Signing failed: \(error.localizedDescription)"))
                throw ExitCode.failure
            }
            let signatureB64 = signatureRaw.base64EncodedString()

            let triple: [(String, String)] = [
                ("X-Spook-Timestamp", timestamp),
                ("X-Spook-Nonce", nonce),
                ("X-Spook-Signature", signatureB64)
            ]

            if curlArgs {
                // Emit `-H "Name: Value"` per triple, each on
                // its own line. `xargs curl ...` concatenates
                // them back onto the curl command.
                for (name, value) in triple {
                    print("-H")
                    print("\(name): \(value)")
                }
            } else {
                for (name, value) in triple {
                    print("\(name): \(value)")
                }
            }
        }
    }
}
