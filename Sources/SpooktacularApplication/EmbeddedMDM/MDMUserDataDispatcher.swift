import Foundation
import os

/// "Run this script on this VM" — the operator-facing seam
/// for the embedded MDM. Wraps a script as a one-shot pkg,
/// stages it in the ``MDMContentStore``, derives the
/// `ManifestURL`, and enqueues an `InstallEnterpriseApplication`
/// command on the handler. Returns the command UUID so callers
/// can correlate with the device's eventual ack.
///
/// ## Why an actor
///
/// Concurrent `dispatch(...)` calls (multiple operators, or
/// the GUI + CLI racing) shouldn't trample each other's
/// content-store inserts. Serialising through an actor is the
/// minimum safe shape; the work itself (pkg build + plist
/// render + enqueue) doesn't fight for shared state once the
/// actor admits it.
///
/// ## Mockable pkg builder seam
///
/// The actual `pkgbuild` + `productbuild` invocation is
/// gated behind ``MDMUserDataPkgBuilding`` so unit tests can
/// inject a fake that returns canned bytes. The production
/// builder lives in `SpooktacularInfrastructureApple` (it
/// uses `Process`, an FS dependency we keep out of
/// `SpooktacularApplication`).
public actor MDMUserDataDispatcher {

    // MARK: - State

    private let handler: SpooktacularMDMHandler
    private let contentStore: MDMContentStore
    private let pkgBuilder: any MDMUserDataPkgBuilding
    private let baseURL: URL
    private let logger: Logger

    // MARK: - Init

    /// - Parameters:
    ///   - handler: The MDM handler that owns the device
    ///     queue. The dispatcher calls `handler.enqueue(_:forUDID:)`.
    ///   - contentStore: Shared with the embedded MDM server's
    ///     manifest + pkg fetch endpoints. The dispatcher
    ///     `register`s; the server reads.
    ///   - pkgBuilder: Builds the .pkg payload from a script.
    ///     Production: ``MDMUserDataPkgBuilder``. Tests: a
    ///     fake conforming type that returns canned bytes.
    ///   - baseURL: Public-facing base URL for the embedded
    ///     MDM server, e.g. `https://host.local:8443`. The
    ///     dispatcher appends `/mdm/manifest/<id>` to derive
    ///     the manifest URL the device fetches.
    ///   - logger: Diagnostic logger.
    public init(
        handler: SpooktacularMDMHandler,
        contentStore: MDMContentStore,
        pkgBuilder: any MDMUserDataPkgBuilding,
        baseURL: URL,
        logger: Logger = Logger(
            subsystem: "com.spookylabs.spooktacular",
            category: "mdm.dispatcher"
        )
    ) {
        self.handler = handler
        self.contentStore = contentStore
        self.pkgBuilder = pkgBuilder
        self.baseURL = baseURL
        self.logger = logger
    }

    // MARK: - Public API

    /// Dispatches the given script to a specific enrolled VM.
    /// Returns the `commandUUID` of the enqueued command so
    /// callers can wait on the response (via the handler's
    /// audit / metrics surfaces).
    ///
    /// The script is wrapped as a one-shot pkg whose
    /// postinstall is the script itself: `installer` runs
    /// the postinstall as root, executing the script in the
    /// guest's system context. After the device acks, the
    /// dispatcher does *not* automatically purge the content
    /// store entry — operator code calls
    /// ``forget(commandID:)`` once it's confident the run is
    /// truly done (e.g. after the audit pipeline records it).
    ///
    /// - Parameters:
    ///   - scriptBody: Bytes of the script (typically a UTF-8
    ///     bash file with `#!/bin/bash` shebang).
    ///   - scriptName: Filename for diagnostics — e.g.
    ///     `setup-jenkins-runner.sh`.
    ///   - udid: Target VM's MDM UDID. Use
    ///     ``MDMDeviceStore/allEnrolled()`` to enumerate
    ///     candidates if you don't have the UDID handy.
    /// - Returns: A handle wrapping the command UUID + the
    ///   content-store ID, so the operator can later
    ///   ``forget(commandID:)`` to free memory.
    public func dispatch(
        scriptBody: Data,
        scriptName: String,
        toUDID udid: String
    ) async throws -> Dispatched {
        logger.notice(
            "Dispatching user-data \(scriptName, privacy: .public) (\(scriptBody.count) bytes) to UDID=\(udid, privacy: .public)"
        )

        // Build the pkg first so the manifest can reference
        // its bytes for chunk MD5s.
        let built = try await pkgBuilder.buildPkg(
            scriptBody: scriptBody,
            scriptName: scriptName
        )

        // Mint the content-store ID up front so we can bake
        // it into the manifest's pkg URL before registering.
        // `MDMContentStore.store(id:…)` accepts a
        // caller-supplied UUID for exactly this case.
        let contentID = UUID()
        let pkgURL = baseURL.appendingPathComponent(
            "mdm/pkg/\(contentID.uuidString)"
        )
        let manifestURL = baseURL.appendingPathComponent(
            "mdm/manifest/\(contentID.uuidString)"
        )
        let manifest = try MDMManifestBuilder.build(
            pkgData: built.pkgData,
            pkgURL: pkgURL,
            bundleIdentifier: built.bundleIdentifier
        )

        await contentStore.store(
            id: contentID,
            pkgData: built.pkgData,
            manifestData: manifest,
            bundleIdentifier: built.bundleIdentifier
        )

        let command = MDMCommand(
            kind: .installEnterpriseApplication(
                manifestURL: manifestURL,
                manifestURLPinningCerts: []
            )
        )
        await handler.enqueue(command, forUDID: udid)

        return Dispatched(
            commandUUID: command.commandUUID,
            contentStoreID: contentID,
            manifestURL: manifestURL
        )
    }

    /// Frees the content-store entry for a previously-dispatched
    /// command. Called by operator code (CLI/GUI/audit
    /// pipeline) once the run is confirmed complete; the
    /// dispatcher itself doesn't auto-purge so a slow device
    /// that retries the install after a long absence still
    /// finds its bytes.
    public func forget(_ dispatched: Dispatched) async {
        await contentStore.remove(dispatched.contentStoreID)
    }

    // MARK: - Return type

    /// Handles for a successful dispatch — surface them to
    /// the operator so they can correlate with audit /
    /// metrics later.
    public struct Dispatched: Sendable, Equatable {
        public let commandUUID: UUID
        public let contentStoreID: UUID
        public let manifestURL: URL
    }
}

// MARK: - Pkg builder protocol

/// Mockable seam over "build a one-shot .pkg from a script."
/// Production: ``MDMUserDataPkgBuilder`` (uses `pkgbuild` +
/// `productbuild` via `Process`). Tests: a fake type
/// returning canned bytes.
public protocol MDMUserDataPkgBuilding: Sendable {

    /// Wraps `scriptBody` as a one-shot installer pkg whose
    /// postinstall script runs the user-data script as root.
    /// Returns the pkg bytes plus the bundle identifier the
    /// pkg declares (passed through to the manifest's
    /// `bundle-identifier`).
    func buildPkg(
        scriptBody: Data,
        scriptName: String
    ) async throws -> BuiltPackage

    /// Tagged tuple so the protocol stays simple but the
    /// impl can return more fields later (postinstall path,
    /// signing identity used, signature digest, etc.) without
    /// breaking the contract.
    typealias BuiltPackage = MDMUserDataBuiltPackage
}

/// Result of ``MDMUserDataPkgBuilding/buildPkg(scriptBody:scriptName:)``.
public struct MDMUserDataBuiltPackage: Sendable, Equatable {
    public let pkgData: Data
    public let bundleIdentifier: String

    public init(pkgData: Data, bundleIdentifier: String) {
        self.pkgData = pkgData
        self.bundleIdentifier = bundleIdentifier
    }
}
