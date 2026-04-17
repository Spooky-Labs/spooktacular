import ArgumentParser
import Foundation
import SpooktacularKit

extension Spook {

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
            abstract: "Bundle-level maintenance: protect, verify.",
            subcommands: [Protect.self],
            defaultSubcommand: Protect.self
        )

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
                      SPOOK_BUNDLE_PROTECTION=cufua spook bundle protect --all   # force CUFUA on desktops
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
