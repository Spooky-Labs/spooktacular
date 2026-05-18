import ArgumentParser
import Foundation
import SpooktacularKit

extension Spooktacular {

    /// Bundle-level maintenance commands.
    ///
    /// Operations that act on the VM bundle directory itself —
    /// not its running state. Currently wraps the data-at-rest
    /// protection migration (`spook bundle protect`). Future
    /// operations (bundle repair, checksum verification, snapshot
    /// vacuum) will land here.
    struct Bundle: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "bundle",
            abstract: "Bundle-level maintenance: protect, import, export.",
            subcommands: [Protect.self, Import.self, Export.self],
            defaultSubcommand: Protect.self
        )

        // MARK: - import

        /// Imports a portable `.vm` bundle into
        /// `~/.spooktacular/vms/`. Shares the `BundleImporter`
        /// primitive with the GUI's drag-and-drop flow, so
        /// machine identifier regeneration, MAC rewrite, and
        /// protection-class application are identical.
        struct Import: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "import",
                abstract: "Import a portable .vm bundle into the library.",
                discussion: """
                    Copies a `.vm` bundle from an arbitrary location \
                    into `~/.spooktacular/vms/` via APFS clonefile(2) \
                    (near-instant on same-volume imports, full copy on \
                    cross-volume). Regenerates the VZMacMachineIdentifier \
                    and MAC address so two imports of the same source \
                    bundle never collide on the host network.

                    If the destination name already exists, an integer \
                    suffix is appended (`my-vm-2`, `my-vm-3`, …) rather \
                    than overwriting.

                    EXAMPLES:
                      spooktacular bundle import /Volumes/USB/ci-runner.vm
                      spooktacular bundle import ~/Downloads/template.vm
                    """
            )

            @Argument(help: "Path to the .vm bundle to import.")
            var source: String

            func run() async throws {
                let sourceURL = URL(filePath: source.expandingTilde)
                guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                    print(Style.error("✗ Source not found: \(source)"))
                    throw ExitCode.failure
                }
                do {
                    let bundle = try BundleImporter.import(
                        sourceURL: sourceURL,
                        intoDirectory: SpooktacularPaths.vms
                    )
                    let name = bundle.url.deletingPathExtension().lastPathComponent
                    print(Style.success("✓ Imported as '\(name)'."))
                    print(Style.dim("  Run 'spooktacular start \(name)' to boot."))
                } catch {
                    print(Style.error("✗ \(error.localizedDescription)"))
                    throw ExitCode.failure
                }
            }
        }

        // MARK: - export

        /// Exports a library VM bundle to an arbitrary location
        /// so it can be moved to another Mac, backed up, or
        /// archived.
        ///
        /// Symmetric with `import`: same copy primitive, no
        /// identity regeneration (the source stays in the
        /// library; the exported copy will be regenerated on
        /// re-import if it's ever brought back).
        struct Export: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "export",
                abstract: "Export a library VM bundle to a portable location.",
                discussion: """
                    Copies a VM bundle from `~/.spooktacular/vms/` to a \
                    destination of your choice via APFS clonefile(2). \
                    The bundle is self-contained — disk image, aux \
                    storage, hardware model, machine identifier — so \
                    the copy is ready to drag to another Mac and \
                    double-click.

                    The source bundle in the library is untouched. If \
                    the destination already exists, the export fails \
                    rather than overwriting.

                    If the VM is suspended (SaveFile.vzvmsave present), \
                    exporting includes the save-file — but save-state \
                    is tied to the source host's VZVirtualMachine \
                    instance and will be deleted when the bundle is \
                    next imported. Consider running \
                    `spooktacular discard-suspend <name>` first if you \
                    want a clean cold-boot on the destination host.

                    EXAMPLES:
                      spooktacular bundle export base --to /Volumes/USB/base.vm
                      spooktacular bundle export ci-runner --to ~/Desktop/
                    """
            )

            @Argument(help: "Name of the VM to export.")
            var name: String

            @Option(name: .long, help: "Destination path. A directory or a .vm path.")
            var to: String

            func run() async throws {
                let bundleURL = try SpooktacularPaths.bundleURL(for: name)
                guard FileManager.default.fileExists(atPath: bundleURL.path) else {
                    print(Style.error("✗ VM '\(name)' not found in the library."))
                    throw ExitCode.failure
                }

                let destinationInput = URL(filePath: to.expandingTilde)
                // If the caller passed a directory, land the
                // bundle inside it with its library name. If
                // they passed a specific `.vm` path, use that
                // verbatim — matches `cp` ergonomics.
                let destination: URL
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: destinationInput.path, isDirectory: &isDir), isDir.boolValue {
                    destination = destinationInput.appendingPathComponent("\(name).vm")
                } else {
                    destination = destinationInput
                }

                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    print(Style.error("✗ Destination already exists: \(destination.path)"))
                    throw ExitCode.failure
                }

                try FileManager.default.copyItem(at: bundleURL, to: destination)
                print(Style.success("✓ Exported '\(name)' → \(destination.path)"))
            }
        }

        // MARK: - protect

        /// Applies the recommended `FileProtectionType` to
        /// existing VM bundles. Implements the migration path
        /// referenced from `docs/DATA_AT_REST.md`.
        struct Protect: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "protect",
                abstract: "Apply data-at-rest protection class to VM bundles.",
                discussion: """
                    Applies the recommended FileProtectionType class to one \
                    or more VM bundles. On portable Macs (laptops with a \
                    battery) the recommended class is \
                    CompleteUntilFirstUserAuthentication, which keeps the \
                    bundle encrypted at rest when the laptop is powered \
                    off — even if the FileVault recovery key is \
                    compromised. Desktops and EC2 Mac hosts get `.none` \
                    so pre-login LaunchDaemons can still read bundles.

                    See docs/DATA_AT_REST.md for the full threat model \
                    and OWASP ASVS mapping.

                    EXAMPLES:
                      spook bundle protect base            # one bundle
                      spook bundle protect --all           # every bundle
                      spook bundle protect base --none     # explicit opt-out
                      SPOOKTACULAR_BUNDLE_PROTECTION=cufua spook bundle protect --all   # force CUFUA on desktops
                    """
            )

            @Argument(help: "VM names to protect. Omit when using --all.")
            var names: [String] = []

            @Flag(help: "Apply to every bundle in ~/.spooktacular/vms/.")
            var all: Bool = false

            @Flag(help: "Explicitly apply `.none` instead of the recommended class.")
            var none: Bool = false

            func run() async throws {
                let vmDir = SpooktacularPaths.vms
                let fm = FileManager.default

                let targetURLs: [URL]
                if all {
                    guard fm.fileExists(atPath: vmDir.path) else {
                        print(Style.info("No bundles found at \(vmDir.path) — nothing to protect."))
                        return
                    }
                    let contents = try fm.contentsOfDirectory(at: vmDir, includingPropertiesForKeys: nil)
                    targetURLs = contents.filter { $0.pathExtension == "vm" }
                } else if !names.isEmpty {
                    targetURLs = try names.map { try SpooktacularPaths.bundleURL(for: $0) }
                } else {
                    print(Style.error("Provide at least one VM name or pass --all."))
                    throw ExitCode.failure
                }

                let (recommended, policy) = BundleProtection.recommendedPolicy()
                let desired: FileProtectionType = none ? .none : recommended

                print(Style.info("Applying \(desired.displayName) to \(targetURLs.count) bundle(s). Policy: \(policy)."))

                var applied = 0
                var failed: [(String, Error)] = []
                for url in targetURLs {
                    let name = url.deletingPathExtension().lastPathComponent
                    do {
                        try BundleProtection.apply(desired, to: url)
                        // Re-apply to every file inside so an older
                        // bundle migrated from `.none` brings its
                        // config.json / metadata.json / disk.img
                        // along for the ride.
                        try BundleProtection.propagate(to: url)
                        print(Style.success("✓ \(name): \(desired.displayName)"))
                        applied += 1
                    } catch {
                        print(Style.error("✗ \(name): \(error.localizedDescription)"))
                        failed.append((name, error))
                    }
                }

                print(Style.dim("\(applied) applied, \(failed.count) failed"))
                if !failed.isEmpty {
                    throw ExitCode.failure
                }
            }
        }
    }
}
