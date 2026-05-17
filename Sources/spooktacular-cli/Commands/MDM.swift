import ArgumentParser
import Foundation
import SpooktacularKit
import SpooktacularApplication
import SpooktacularInfrastructureApple
import SpooktacularCore

extension Spooktacular {

    /// Operator surface for Spooktacular's embedded MDM —
    /// "I want this VM to enroll, and I want to push scripts
    /// to it."
    ///
    /// ## The three commands you need
    ///
    /// 1. `spook mdm init` — one-time host setup (root CA,
    ///    server identity). Idempotent.
    /// 2. `spook mdm serve` — runs the MDM listener.
    /// 3. `spook mdm enroll <vm>` — injects the enrollment
    ///    profile into a VM bundle. Next boot auto-enrolls.
    ///
    /// That's it. Signing + TLS are on by default. Operators
    /// who want the underlying knobs can pass `--unsigned`,
    /// `--no-tls`, `--print-only` for inspection.
    struct MDM: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "mdm",
            abstract: "Embedded MDM — enroll Spooktacular VMs and push commands.",
            discussion: """
                The embedded MDM lets Spooktacular act as its \
                own management server for the VMs it spawns. \
                Once a VM enrolls, the host can push \
                profiles, install pkgs, and run user-data \
                scripts — no third-party Jamf/Kandji needed \
                for VM-scope management.

                TYPICAL FLOW:
                  spook mdm init                   # once per host
                  spook mdm serve --host <addr>    # run the server
                  spook mdm enroll <vm>            # bootstrap a VM
                  spook start <vm>                 # boot it — auto-enrolls
                  spook mdm run <vm> setup.sh      # push a script
                  spook mdm devices                # see enrolled VMs

                Defaults are secure: signed enrollment + TLS \
                are on. Pass --unsigned or --no-tls when \
                experimenting on loopback.
                """,
            subcommands: [Init.self, Serve.self, Enroll.self, Run.self, Devices.self, Doctor.self]
        )

        // MARK: - init

        /// One-time host setup: generates the root CA. Calling
        /// it explicitly makes the bootstrap step in
        /// ``Enroll`` a no-op; calling neither lets ``Enroll``
        /// implicitly generate.
        struct Init: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "One-time host setup — generates the embedded MDM root CA."
            )

            @Option(
                name: .customLong("storage"),
                help: "Directory for the root CA. Defaults to ~/.spooktacular/mdm/."
            )
            var storage: String?

            mutating func run() async throws {
                let storageDir = Self.resolveStorageDir(override: storage)
                let issuer: MDMIdentityIssuer
                do {
                    issuer = try MDMIdentityIssuer(storageDirectory: storageDir)
                } catch {
                    print(Style.error("Failed to initialise issuer: \(error.localizedDescription)"))
                    throw ExitCode.failure
                }
                // Force-touch the CA so subsequent commands
                // start synchronously rather than paying the
                // generation cost on first use.
                do {
                    _ = try await issuer.rootCertificateDER()
                } catch {
                    print(Style.error("Failed to bootstrap root CA: \(error.localizedDescription)"))
                    throw ExitCode.failure
                }
                print(Style.bold("Embedded MDM initialised"))
                print()
                Style.field("Storage", storageDir.path)
                Style.field(
                    "Root CA",
                    storageDir.appendingPathComponent("root-ca.pem").path
                )
                print()
                print(Style.dim("Run `spook mdm serve` to start accepting enrollments."))
            }

            static func resolveStorageDir(override: String?) -> URL {
                if let override {
                    return URL(fileURLWithPath: override)
                }
                return SpooktacularPaths.root.appendingPathComponent("mdm", isDirectory: true)
            }
        }

        // MARK: - serve

        struct Serve: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Run the embedded MDM listener in the foreground."
            )

            @Option(
                name: .customLong("host"),
                help: "Bind address. Use the host's bridged-NIC IP so VMs can reach it."
            )
            var host: String = "127.0.0.1"

            @Option(name: .customLong("port"), help: "Port to bind.")
            var port: Int = Int(EmbeddedMDMServer.defaultPort)

            @Flag(
                name: .customLong("no-tls"),
                help: "Disable TLS. Loopback / dev use only."
            )
            var noTLS: Bool = false

            @Option(
                name: .customLong("tls-san"),
                parsing: .upToNextOption,
                help: "Additional SAN entries for the server certificate (DNS names or IPs)."
            )
            var tlsSANs: [String] = []

            @Option(
                name: .customLong("storage"),
                help: "Directory containing the root CA. Defaults to ~/.spooktacular/mdm/."
            )
            var storage: String?

            mutating func run() async throws {
                let storageDir = Init.resolveStorageDir(override: storage)
                let devicesURL = storageDir
                    .appendingPathComponent("state", isDirectory: true)
                    .appendingPathComponent("devices.json")
                let persister = MDMDeviceStorePersister(fileURL: devicesURL)

                let store: MDMDeviceStore
                do {
                    store = try await persister.load()
                } catch {
                    print(Style.warning("Failed to load existing device snapshot — starting empty: \(error.localizedDescription)"))
                    store = MDMDeviceStore()
                }
                let queue = MDMCommandQueue()
                let handler = SpooktacularMDMHandler(
                    deviceStore: store,
                    commandQueue: queue,
                    persister: persister
                )
                let content = MDMContentStore()

                var serverIdentity: EmbeddedMDMServer.ServerIdentity?
                if !noTLS {
                    let storageDir = Init.resolveStorageDir(override: storage)
                    let issuer = try MDMIdentityIssuer(storageDirectory: storageDir)
                    let cert = try await issuer.serverCertificate(
                        forHost: host,
                        additionalHosts: tlsSANs
                    )
                    serverIdentity = EmbeddedMDMServer.ServerIdentity(
                        pkcs12Data: cert.pkcs12Data,
                        password: cert.password
                    )
                }

                let server = try EmbeddedMDMServer(
                    host: host,
                    port: UInt16(port),
                    handler: handler,
                    contentStore: content,
                    serverIdentity: serverIdentity
                )
                try await server.start()

                let actualPort = await server.boundPort ?? UInt16(port)
                let scheme = (await server.isTLSEnabled) ? "https" : "http"

                // Start a background outbox-drain loop so
                // `spook mdm run` from another shell can
                // dispatch user-data via the filesystem.
                let outbox = MDMDispatchOutbox(
                    directory: Init.resolveStorageDir(override: storage)
                        .appendingPathComponent("state", isDirectory: true)
                        .appendingPathComponent("outbox", isDirectory: true)
                )
                let dispatcher = MDMUserDataDispatcher(
                    handler: handler,
                    contentStore: content,
                    pkgBuilder: MDMUserDataPkgBuilder(),
                    baseURL: URL(string: "\(scheme)://\(host):\(actualPort)")!
                )
                Task.detached {
                    while !Task.isCancelled {
                        await outbox.drain { request in
                            guard let scriptBody = request.scriptBody else {
                                return .failed(reason: "Malformed script body")
                            }
                            do {
                                _ = try await dispatcher.dispatch(
                                    scriptBody: scriptBody,
                                    scriptName: request.scriptName,
                                    toUDID: request.udid
                                )
                                return .delivered
                            } catch {
                                return .failed(reason: error.localizedDescription)
                            }
                        }
                        try? await Task.sleep(for: .seconds(2))
                    }
                }

                print(Style.bold("Spooktacular MDM"))
                print()
                Style.field("Listening", "\(scheme)://\(host):\(actualPort)")
                Style.field("TLS", (await server.isTLSEnabled) ? "enabled" : "disabled")
                Style.field("Outbox", outbox.directory.path)
                print()
                print(Style.dim("Press Ctrl+C to stop."))
                print()

                let shutdownServer = server
                for sig in [SIGTERM, SIGINT] {
                    signal(sig, SIG_IGN)
                    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                    source.setEventHandler {
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

        // MARK: - enroll

        struct Enroll: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Bootstrap MDM enrollment for a VM — injects a first-boot script that auto-enrolls.",
                discussion: """
                    Writes the enrollment profile into the VM \
                    bundle's first-boot slot. The VM must \
                    already have Spooktacular Provisioner.pkg \
                    installed (run that once from inside Guest \
                    Tools). On next boot the profile auto- \
                    installs and mdmclient dials the host's \
                    MDM server.

                    Defaults: signed enrollment (per-VM \
                    identity cert), HTTPS server URL. Override \
                    with --unsigned for loopback testing.
                    """
            )

            @Argument(help: "VM name.")
            var vm: String

            @Option(
                name: .customLong("server"),
                help: "MDM server address VMs reach. Use the host's bridged-NIC IP."
            )
            var server: String = "127.0.0.1"

            @Option(name: .customLong("port"), help: "MDM server port.")
            var port: Int = Int(EmbeddedMDMServer.defaultPort)

            @Flag(
                name: .customLong("unsigned"),
                help: "Skip per-VM identity cert. Pairs with `mdm serve --no-tls`; loopback only."
            )
            var unsigned: Bool = false

            @Flag(
                name: .customLong("no-tls"),
                help: "Use http:// in the embedded server URL. Pair with `--unsigned`."
            )
            var noTLS: Bool = false

            @Flag(
                name: .customLong("print-only"),
                help: "Print the bootstrap script to stdout without modifying the bundle."
            )
            var printOnly: Bool = false

            @Option(
                name: .customLong("storage"),
                help: "MDM root CA directory. Defaults to ~/.spooktacular/mdm/."
            )
            var storage: String?

            mutating func run() async throws {
                let bundleURL: URL
                do {
                    bundleURL = try SpooktacularPaths.resolveBundle(selector: vm)
                } catch {
                    print(Style.error("VM '\(vm)' not found: \(error.localizedDescription)"))
                    throw ExitCode.failure
                }
                let bundle = try VirtualMachineBundle.load(from: bundleURL)
                let scheme = noTLS ? "http" : "https"

                guard let serverURL = URL(string: "\(scheme)://\(server):\(port)/mdm/server"),
                      let checkInURL = URL(string: "\(scheme)://\(server):\(port)/mdm/checkin")
                else {
                    print(Style.error("Invalid server/port combination."))
                    throw ExitCode.failure
                }

                let signaturePolicy: MDMEnrollmentProfile.SignaturePolicy
                if unsigned {
                    signaturePolicy = .unsigned
                } else {
                    let storageDir = Init.resolveStorageDir(override: storage)
                    let issuer = try MDMIdentityIssuer(storageDirectory: storageDir)
                    let identity = try await issuer.issueIdentity(forUDID: bundle.id.uuidString)
                    signaturePolicy = .signed(identity: identity)
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
                    }
                    return
                }

                try DiskInjector.injectMDMEnrollment(bootstrap: bootstrap, into: bundle)

                print(Style.bold("Enrolled \(bundle.displayName)"))
                print()
                Style.field("Server", serverURL.absoluteString)
                Style.field("Mode", unsigned ? "unsigned (loopback)" : "signed (per-VM identity)")
                Style.field("First-boot", bundle.provisionScriptURL.path)
                print()
                print(Style.dim("Boot the VM and it will enroll automatically."))
                print(Style.dim("Requires Spooktacular Provisioner.pkg already installed in the guest."))
            }
        }

        // MARK: - run

        /// Push a user-data script to an enrolled VM. Writes
        /// to a file-backed outbox; `spook mdm serve` picks
        /// it up on its next poll, builds the pkg, and
        /// enqueues an InstallEnterpriseApplication command.
        struct Run: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Push a user-data script to an enrolled VM."
            )

            @Argument(help: "VM name (must already be enrolled).")
            var vm: String

            @Argument(help: "Path to the script to run. Reads from stdin if '-'.")
            var script: String

            @Option(
                name: .customLong("storage"),
                help: "MDM root directory. Defaults to ~/.spooktacular/mdm/."
            )
            var storage: String?

            mutating func run() async throws {
                let bundleURL: URL
                do {
                    bundleURL = try SpooktacularPaths.resolveBundle(selector: vm)
                } catch {
                    print(Style.error("VM '\(vm)' not found: \(error.localizedDescription)"))
                    throw ExitCode.failure
                }
                let bundle = try VirtualMachineBundle.load(from: bundleURL)
                let udid = bundle.id.uuidString

                // Validate the VM is enrolled by looking up
                // the persisted device snapshot. Without
                // enrollment, the dispatch is meaningless.
                let storageDir = Init.resolveStorageDir(override: storage)
                let devicesURL = storageDir
                    .appendingPathComponent("state", isDirectory: true)
                    .appendingPathComponent("devices.json")
                let persister = MDMDeviceStorePersister(fileURL: devicesURL)
                let records = (try? persister.readRecords()) ?? []
                guard let record = records.first(where: { $0.udid == udid }),
                      !record.checkedOut else {
                    print(Style.error("VM '\(vm)' isn't currently enrolled."))
                    print(Style.dim("Run `spook mdm enroll \(vm)` + start the VM first."))
                    throw ExitCode.failure
                }

                let body: Data
                if script == "-" {
                    body = FileHandle.standardInput.readDataToEndOfFile()
                } else {
                    let url = URL(fileURLWithPath: script)
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        print(Style.error("Script '\(script)' not found."))
                        throw ExitCode.failure
                    }
                    body = try Data(contentsOf: url)
                }
                guard !body.isEmpty else {
                    print(Style.error("Script body is empty."))
                    throw ExitCode.failure
                }

                let outbox = MDMDispatchOutbox(
                    directory: storageDir
                        .appendingPathComponent("state", isDirectory: true)
                        .appendingPathComponent("outbox", isDirectory: true)
                )
                let scriptName = (script == "-")
                    ? "stdin.sh"
                    : URL(fileURLWithPath: script).lastPathComponent
                let request = MDMDispatchOutbox.Request(
                    udid: udid,
                    scriptName: scriptName,
                    scriptBody: body
                )
                let queued = try await outbox.submit(request)

                print(Style.bold("Queued user-data for \(bundle.displayName)"))
                print()
                Style.field("Command UUID", queued.commandUUID.uuidString)
                Style.field("Script", scriptName)
                Style.field("Bytes", "\(body.count)")
                print()
                print(Style.dim("`spook mdm serve` will pick this up on its next poll (≤ 2s)."))
            }
        }

        // MARK: - devices

        /// Lists enrolled devices. Reads from the host's
        /// last-known device-store snapshot on disk (written
        /// by `serve` on shutdown / interval).
        ///
        /// Until persistence ships, this command can only see
        /// devices that enrolled during the currently-running
        /// `serve`. We print a helpful note when the snapshot
        /// is missing.
        struct Devices: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "List MDM-enrolled VMs."
            )

            @Option(
                name: .customLong("storage"),
                help: "MDM root directory. Defaults to ~/.spooktacular/mdm/."
            )
            var storage: String?

            mutating func run() async throws {
                let storageDir = Init.resolveStorageDir(override: storage)
                let snapshotURL = storageDir
                    .appendingPathComponent("state", isDirectory: true)
                    .appendingPathComponent("devices.json")
                let persister = MDMDeviceStorePersister(fileURL: snapshotURL)
                let records: [MDMDeviceStore.Record]
                do {
                    records = try persister.readRecords()
                } catch {
                    print(Style.error("Failed to read device snapshot: \(error.localizedDescription)"))
                    throw ExitCode.failure
                }
                let active = records.filter { !$0.checkedOut }
                if active.isEmpty {
                    print(Style.dim("No enrolled devices."))
                    if records.isEmpty {
                        print(Style.dim("Start `spook mdm serve` and enroll at least one VM."))
                    } else {
                        print(Style.dim("\(records.count) device(s) in the snapshot are checked out."))
                    }
                    return
                }
                print(Style.bold("Enrolled devices (\(active.count))"))
                print()
                for r in active.sorted(by: { $0.udid < $1.udid }) {
                    let model = r.model ?? "?"
                    let os = r.osVersion ?? "?"
                    let seen = Self.relative(r.lastSeen)
                    Style.field(r.udid, "\(model) · macOS \(os) · last seen \(seen)")
                }
            }

            private static func relative(_ date: Date) -> String {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .abbreviated
                return formatter.localizedString(for: date, relativeTo: Date())
            }
        }

        // MARK: - doctor

        /// Health-check the MDM setup. Useful for "is this
        /// actually configured right?" without running a full
        /// enrollment.
        struct Doctor: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Validate the host's MDM setup."
            )

            @Option(
                name: .customLong("storage"),
                help: "MDM root directory. Defaults to ~/.spooktacular/mdm/."
            )
            var storage: String?

            mutating func run() async throws {
                let storageDir = Init.resolveStorageDir(override: storage)
                var issues: [String] = []

                if !FileManager.default.fileExists(atPath: storageDir.path) {
                    issues.append("Storage directory missing — run `spook mdm init`.")
                }
                let caPEM = storageDir.appendingPathComponent("root-ca.pem")
                let caKey = storageDir.appendingPathComponent("root-ca.key")
                if !FileManager.default.fileExists(atPath: caPEM.path) {
                    issues.append("Root CA cert missing — run `spook mdm init`.")
                }
                if !FileManager.default.fileExists(atPath: caKey.path) {
                    issues.append("Root CA key missing — run `spook mdm init`.")
                }
                if !FileManager.default.fileExists(atPath: "/usr/bin/openssl") {
                    issues.append("`/usr/bin/openssl` not found — required for cert issuance.")
                }

                if issues.isEmpty {
                    print(Style.bold("MDM setup looks healthy."))
                    print()
                    Style.field("Storage", storageDir.path)
                } else {
                    print(Style.error("MDM setup has issues:"))
                    for issue in issues {
                        print("  • \(issue)")
                    }
                    throw ExitCode.failure
                }
            }
        }
    }
}

// The `Devices` subcommand reads `~/.spooktacular/mdm/state/devices.json`
// via MDMDeviceStorePersister, which owns the JSON shape. No
// shadow DTO needed.
