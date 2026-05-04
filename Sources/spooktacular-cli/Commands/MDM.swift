import ArgumentParser
import Foundation
import SpooktacularKit
import SpooktacularApplication
import SpooktacularInfrastructureApple
import SpooktacularCore

extension Spooktacular {

    /// Operator surface for the embedded MDM. Today's
    /// subcommands cover the host-side flow that has to
    /// happen before a VM enrolls: generating + injecting
    /// the enrollment bootstrap into a bundle.
    ///
    /// Future subcommands:
    /// - `serve` — start the embedded MDM listener alongside
    ///   `spook serve` (currently the listener has to be
    ///   started programmatically; CLI integration follows).
    /// - `dispatch` — push a user-data script to an enrolled
    ///   VM via InstallEnterpriseApplication.
    /// - `devices` — list enrolled devices + queue depths.
    struct MDM: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "mdm",
            abstract: "Operator surface for Spooktacular's embedded MDM.",
            discussion: """
                Embedded MDM = Spooktacular acts as its own \
                MDM server for the VMs it spawns. Once a VM \
                enrolls, the host can push profiles, run \
                user-data, and observe device state over the \
                MDM protocol — no third-party Jamf/Kandji \
                needed for VM-scope management.

                EXAMPLES:
                  spook mdm bootstrap my-vm \\
                    --mdm-host 192.168.64.1 --mdm-port 8443

                  # Inspect the generated bootstrap script
                  spook mdm bootstrap my-vm --print-only \\
                    --mdm-host 127.0.0.1
                """,
            subcommands: [Bootstrap.self, Serve.self]
        )

        // MARK: - bootstrap

        struct Bootstrap: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Inject an MDM enrollment script into a VM bundle's first-boot slot.",
                discussion: """
                    Renders the per-VM enrollment .mobileconfig \
                    and embeds it in a bash script that runs at \
                    the next boot via the spook-provision-runner \
                    LaunchDaemon (installed by Spooktacular \
                    Provisioner.pkg from inside Guest Tools).

                    The VM must already be stopped — the script \
                    is written to <bundle>.vm/provision/first-boot.sh \
                    and consumed by the next boot.

                    Repeated invocations replace the previous \
                    bootstrap atomically.
                    """
            )

            @Argument(help: "Name of the VM bundle (case-sensitive).")
            var vm: String

            @Option(
                name: .customLong("mdm-host"),
                help: "Host the VM should reach the embedded MDM server on (defaults to the host's bridged-network address)."
            )
            var mdmHost: String = "127.0.0.1"

            @Option(
                name: .customLong("mdm-port"),
                help: "Port for the embedded MDM server."
            )
            var mdmPort: Int = Int(EmbeddedMDMServer.defaultPort)

            @Option(
                name: .customLong("scheme"),
                help: "URL scheme for the MDM server. Use http for local / dev (no TLS yet); https when CA + identity certs are wired."
            )
            var scheme: String = "http"

            @Flag(
                name: .customLong("print-only"),
                help: "Render the bootstrap script and write it to stdout without modifying the bundle."
            )
            var printOnly: Bool = false

            @Flag(
                name: .customLong("signed"),
                help: "Mint a per-VM identity certificate and embed it in the enrollment profile. Without this flag the profile is unsigned (dev / loopback only)."
            )
            var signed: Bool = false

            @Option(
                name: .customLong("ca-storage"),
                help: "Directory to store the MDM root CA. Generated on first --signed call. Defaults to ~/Library/Application Support/Spooktacular/mdm/."
            )
            var caStorage: String?

            mutating func run() async throws {
                let bundleURL: URL
                do {
                    bundleURL = try SpooktacularPaths.resolveBundle(selector: vm)
                } catch {
                    print(Style.error("Failed to resolve VM '\(vm)': \(error.localizedDescription)"))
                    throw ExitCode.failure
                }

                let bundle: VirtualMachineBundle
                do {
                    bundle = try VirtualMachineBundle.load(from: bundleURL)
                } catch {
                    print(Style.error("Failed to load bundle: \(error.localizedDescription)"))
                    throw ExitCode.failure
                }

                guard let serverURL = URL(string: "\(scheme)://\(mdmHost):\(mdmPort)/mdm/server") else {
                    print(Style.error("Invalid --scheme/--mdm-host/--mdm-port combination"))
                    throw ExitCode.failure
                }
                guard let checkInURL = URL(string: "\(scheme)://\(mdmHost):\(mdmPort)/mdm/checkin") else {
                    print(Style.error("Failed to construct check-in URL"))
                    throw ExitCode.failure
                }

                let signaturePolicy: MDMEnrollmentProfile.SignaturePolicy
                if signed {
                    let storageDir: URL
                    if let caStorage {
                        storageDir = URL(fileURLWithPath: caStorage)
                    } else {
                        storageDir = SpooktacularPaths.root
                            .appendingPathComponent("mdm", isDirectory: true)
                    }
                    let issuer: MDMIdentityIssuer
                    do {
                        issuer = try MDMIdentityIssuer(storageDirectory: storageDir)
                    } catch {
                        print(Style.error("Failed to initialise MDM identity issuer: \(error.localizedDescription)"))
                        throw ExitCode.failure
                    }
                    let identity: MDMEnrollmentProfile.IdentityCertificate
                    do {
                        identity = try await issuer.issueIdentity(
                            forUDID: bundle.id.uuidString
                        )
                    } catch {
                        print(Style.error("Failed to issue identity certificate: \(error.localizedDescription)"))
                        throw ExitCode.failure
                    }
                    signaturePolicy = .signed(identity: identity)
                } else {
                    signaturePolicy = .unsigned
                }

                let profile = MDMEnrollmentProfile.random(
                    vmID: bundle.id,
                    serverURL: serverURL,
                    checkInURL: checkInURL,
                    signaturePolicy: signaturePolicy
                )
                let bootstrap = MDMEnrollmentBootstrap(profile: profile)

                if printOnly {
                    let script = try bootstrap.script()
                    if let s = String(data: script, encoding: .utf8) {
                        print(s)
                    } else {
                        print(Style.error("Bootstrap script not UTF-8"))
                        throw ExitCode.failure
                    }
                    return
                }

                do {
                    try DiskInjector.injectMDMEnrollment(
                        bootstrap: bootstrap, into: bundle
                    )
                } catch {
                    print(Style.error("Failed to inject enrollment: \(error.localizedDescription)"))
                    throw ExitCode.failure
                }

                print(Style.bold("MDM enrollment bootstrap injected"))
                print()
                Style.field("VM", bundle.displayName)
                Style.field("Bundle", Style.dim(bundle.url.path))
                Style.field("MDM server", serverURL.absoluteString)
                Style.field("Signing", signed ? "signed (per-VM identity)" : "unsigned (dev mode)")
                Style.field("First-boot script", bundle.provisionScriptURL.path)
                print()
                print(Style.dim("Next boot of this VM will install the enrollment profile."))
                print(Style.dim("Requires Spooktacular Provisioner.pkg already installed in the guest."))
            }
        }

        // MARK: - serve

        struct Serve: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Run the embedded MDM server in the foreground.",
                discussion: """
                    Binds the MDM HTTP server on the given host \
                    + port. VMs whose enrollment profile points \
                    at this server check in / poll / ack via \
                    /mdm/checkin and /mdm/server.

                    State (device store + command queue) is \
                    in-memory only — restarting wipes it. \
                    Devices naturally re-Authenticate on their \
                    next boot, so transient state loss is \
                    self-healing for enrollment but loses any \
                    queued commands.

                    Run alongside `spook serve` (different port) \
                    until the two are merged into one process.
                    """
            )

            @Option(
                name: .customLong("host"),
                help: "Bind address. Loopback by default; set to a routable address when VMs are on a bridged network."
            )
            var host: String = "127.0.0.1"

            @Option(
                name: .customLong("port"),
                help: "Port to bind."
            )
            var port: Int = Int(EmbeddedMDMServer.defaultPort)

            mutating func run() async throws {
                let store = MDMDeviceStore()
                let queue = MDMCommandQueue()
                let handler = SpooktacularMDMHandler(
                    deviceStore: store,
                    commandQueue: queue
                )
                let content = MDMContentStore()

                let server: EmbeddedMDMServer
                do {
                    server = try EmbeddedMDMServer(
                        host: host,
                        port: UInt16(port),
                        handler: handler,
                        contentStore: content
                    )
                } catch {
                    print(Style.error("Failed to create MDM server: \(error.localizedDescription)"))
                    throw ExitCode.failure
                }

                do {
                    try await server.start()
                } catch {
                    print(Style.error("MDM server failed to bind: \(error.localizedDescription)"))
                    throw ExitCode.failure
                }

                let actualPort = await server.boundPort ?? UInt16(port)
                print(Style.bold("Embedded MDM Server"))
                print()
                Style.field("Bind", "http://\(host):\(actualPort)")
                Style.field("Check-in", "/mdm/checkin")
                Style.field("Command poll", "/mdm/server")
                Style.field("Manifest fetch", "/mdm/manifest/<id>")
                Style.field("Pkg fetch", "/mdm/pkg/<id>")
                print()
                print(Style.dim("Press Ctrl+C to stop."))
                print()

                // Park forever — `await server.start()` returned
                // already-running; we just need to keep the
                // process alive so the listener doesn't get
                // torn down.
                let shutdownServer = server
                for sig in [SIGTERM, SIGINT] {
                    signal(sig, SIG_IGN)
                    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                    source.setEventHandler {
                        let sigName = sig == SIGTERM ? "SIGTERM" : "SIGINT"
                        print("\nReceived \(sigName) — shutting down MDM server...")
                        Task {
                            await shutdownServer.stop()
                            Foundation.exit(0)
                        }
                    }
                    source.resume()
                }
                try await Task.sleep(for: .seconds(Double(Int.max)))
            }
        }
    }
}
