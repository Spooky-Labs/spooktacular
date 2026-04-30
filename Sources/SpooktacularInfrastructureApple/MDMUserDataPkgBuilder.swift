import Foundation
import SpooktacularApplication

/// Production ``MDMUserDataPkgBuilding`` — wraps a script as
/// a one-shot installer pkg using `pkgbuild` + `productbuild`.
///
/// ## Layout the builder constructs in a tempdir
///
/// ```
/// <tmp>/
///   pkg-root/                    (empty — we ship no payload files;
///                                 the script lives in postinstall)
///   pkg-scripts/
///     postinstall                (chmod 755, content = scriptBody)
/// ```
///
/// `pkgbuild --root pkg-root --scripts pkg-scripts ...` produces
/// a component pkg that, when run, executes `postinstall` as root
/// — i.e. the user's script itself. `productbuild --package …`
/// then wraps that in a Distribution-format pkg so Apple's
/// `installer` (and `mdmclient`'s `InstallEnterpriseApplication`
/// path) can install it cleanly.
///
/// ## Why no payload
///
/// The script needs to *run*, not be *installed*. There's no
/// reason to drop a copy onto the device's filesystem. Putting
/// the script body inline as `postinstall` is the smallest pkg
/// shape that still triggers an `installer` invocation, and it
/// leaves no artifact on disk after the run completes.
///
/// ## Bundle-identifier strategy
///
/// Each call mints a fresh UUID-based identifier
/// (`com.spookylabs.userdata.<uuid>`). `mdmclient` uses the
/// bundle identifier to suppress duplicate installs, so a
/// fresh identifier per dispatch is critical — without it,
/// pushing the "same" script twice to a VM would no-op the
/// second time even if the script body changed.
///
/// ## Signing + notarization
///
/// Phase 7 ships the unsigned pkg. Phase 2's CA work + a
/// follow-up commit will plumb in `productsign` (against the
/// Developer ID Installer cert) and notarytool. Until then the
/// pkg is unsigned — fine for dev/CI, blocked by Gatekeeper for
/// distributed deployments.
public struct MDMUserDataPkgBuilder: MDMUserDataPkgBuilding {

    /// Override only in tests that mock out the binaries.
    /// Production reads from PATH defaults.
    public let pkgbuildPath: String
    public let productbuildPath: String

    public init(
        pkgbuildPath: String = "/usr/bin/pkgbuild",
        productbuildPath: String = "/usr/bin/productbuild"
    ) {
        self.pkgbuildPath = pkgbuildPath
        self.productbuildPath = productbuildPath
    }

    public func buildPkg(
        scriptBody: Data,
        scriptName: String
    ) async throws -> MDMUserDataBuiltPackage {
        let fm = FileManager.default
        let tmpRoot = fm.temporaryDirectory
            .appendingPathComponent("spook-mdm-userdata-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpRoot) }

        let pkgRoot = tmpRoot.appendingPathComponent("pkg-root")
        let scripts = tmpRoot.appendingPathComponent("scripts")
        try fm.createDirectory(at: pkgRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: scripts, withIntermediateDirectories: true)

        // Write the user's script body verbatim as `postinstall`.
        // pkgbuild requires this exact filename — it's the
        // documented "fires after package payload extracts"
        // hook, run as root by Installer.
        let postinstall = scripts.appendingPathComponent("postinstall")
        try scriptBody.write(to: postinstall)
        try fm.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: postinstall.path
        )

        let identifier = "com.spookylabs.userdata.\(UUID().uuidString.lowercased())"

        let component = tmpRoot.appendingPathComponent("component.pkg")
        try Self.runProcess(
            pkgbuildPath,
            arguments: [
                "--root", pkgRoot.path,
                "--scripts", scripts.path,
                "--identifier", identifier,
                "--version", "1.0",
                "--install-location", "/",
                component.path
            ]
        )

        let distribution = tmpRoot.appendingPathComponent("distribution.pkg")
        try Self.runProcess(
            productbuildPath,
            arguments: [
                "--package", component.path,
                distribution.path
            ]
        )

        let bytes = try Data(contentsOf: distribution)
        return MDMUserDataBuiltPackage(
            pkgData: bytes,
            bundleIdentifier: identifier
        )
    }

    // MARK: - Process plumbing

    /// Runs a process to completion. Throws if the process
    /// exits non-zero or fails to launch.
    private static func runProcess(_ path: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        // pkgbuild + productbuild emit verbose output we don't
        // want littering the host's stdout. Discard it; if the
        // command fails, we throw with the exit code, and
        // diagnostic output goes via the unified log via the
        // caller's logger.
        let nullHandle = FileHandle.nullDevice
        process.standardOutput = nullHandle
        process.standardError = nullHandle

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw MDMUserDataPkgBuilderError.processFailed(
                command: path,
                exitCode: process.terminationStatus,
                arguments: arguments
            )
        }
    }
}

/// Errors thrown by ``MDMUserDataPkgBuilder``.
public enum MDMUserDataPkgBuilderError: Error, Sendable, Equatable {
    /// `pkgbuild` or `productbuild` exited non-zero. The
    /// arguments are preserved in the error so audit /
    /// diagnostics can reconstruct the exact invocation.
    case processFailed(command: String, exitCode: Int32, arguments: [String])
}
