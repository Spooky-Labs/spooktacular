import Foundation
import NetworkExtension
import os
import SpooktacularCore

/// Host-side configurator for the Spooktacular content
/// filter, built on Apple's `NEFilterManager` /
/// `NEFilterProviderConfiguration` classes.
///
/// ## Architecture at a glance
///
/// ```
/// ┌───────────────────────┐   config via   ┌──────────────────────────┐
/// │  Main app / CLI       │ ─────────────▶ │  NEFilterManager         │
/// │  NEFilterConfigurator │                │  (system-managed store)  │
/// └───────────────────────┘                └──────────────────────────┘
///                                                       │ vendorConfiguration
///                                                       ▼
///                                          ┌──────────────────────────┐
///                                          │ SpooktacularNetworkFilter│
///                                          │ (system extension,       │
///                                          │  NEFilterDataProvider)   │
///                                          └──────────────────────────┘
///                                                       │ per-flow
///                                                       ▼
///                                          [allow / drop]
/// ```
///
/// The main process never does filtering itself. It writes
/// policy into `NEFilterManager`'s system-managed
/// configuration, which propagates the policy to the system
/// extension over the standard NE configuration channel. The
/// extension applies `handleNewFlow(_:)` per TCP/UDP flow.
///
/// ## Why this replaces the earlier `pf` approach
///
/// - **No root required.** `NEFilterManager` is user-scoped;
///   main app configures the filter without sudo prompts.
/// - **Hostname-aware.** The extension sees
///   `NEFilterFlow.remoteEndpoint` as a `NWHostEndpoint` with
///   the original hostname (not just resolved IP), so
///   "allow github.com" rules survive DNS churn.
/// - **Observable.** The filter shows up in System Settings
///   → Network → Filters. Console.app captures its
///   lifecycle. MDM can push its configuration silently.
///
/// ## Apple APIs
///
/// - [`NEFilterManager`](https://developer.apple.com/documentation/networkextension/nefiltermanager)
///   — app-facing singleton for loading/saving the
///   preferences.
/// - [`NEFilterProviderConfiguration`](https://developer.apple.com/documentation/networkextension/nefilterproviderconfiguration)
///   — the configuration the extension reads.
/// - `vendorConfiguration: [String: Any]?` — arbitrary
///   JSON-serializable policy. Our policy travels here.
/// - [`NEFilterDataProvider`](https://developer.apple.com/documentation/networkextension/nefilterdataprovider)
///   — the provider class the extension target subclasses.
///
/// ## Entitlement
///
/// - **Main app / CLI:** `com.apple.developer.networking.networkextension`
///   with the `content-filter-provider` subtype.
/// - **Extension bundle:** same entitlement, plus the
///   standard system-extension packaging.
public actor NEFilterConfigurator {

    private static let log = Logger(
        subsystem: "com.spooktacular.app",
        category: "ne-filter-configurator"
    )

    /// Bundle identifier of the system extension we install
    /// alongside the main app. Must match the extension
    /// target's bundle-identifier in `project.yml` (added in
    /// Phase B — the packaging pass).
    public static let extensionBundleIdentifier = "com.spooktacular.app.NetworkFilter"

    /// Human-visible description shown in System Settings →
    /// Network → Filters. Apple documents this as the
    /// `localizedDescription` of the provider configuration.
    public static let filterLocalizedDescription = "Spooktacular — VM Egress Policy"

    /// Trivial initializer. The configurator is stateless —
    /// all state lives in the `NEFilterManager` shared
    /// instance the methods below fetch at call time.
    public init() {}

    /// Writes the active policies to the shared
    /// `NEFilterManager` configuration. The extension picks
    /// them up over the NE configuration channel; no process
    /// restart required.
    ///
    /// Replaces the entire vendor configuration rather than
    /// merging — the policy set is the source of truth. Call
    /// this on any add/remove/update to keep the extension
    /// in sync.
    public func applyPolicies(
        _ policies: [TenantEgressPolicy],
        vmBySourceIP: [String: (tenant: String, vmName: String)]
    ) async throws {
        let manager = NEFilterManager.shared()
        try await manager.loadFromPreferences()

        // Build the provider configuration from scratch.
        // `NEFilterManager.providerConfiguration` is the
        // currently-installed one; we overwrite it.
        let providerConfig = NEFilterProviderConfiguration()
        // `filterBrowsers` is iOS-only; on macOS only
        // `filterSockets` matters (per Apple docs, setting
        // `filterBrowsers` on macOS is a no-op / deprecated).
        providerConfig.filterSockets = true
        // Packet-level filtering is `NEFilterPacketProvider`'s
        // job — we don't ship one. Explicit-false documents
        // intent.
        providerConfig.filterPackets = false
        providerConfig.organization = "Spooktacular"
        // Explicitly name the Data Provider's bundle ID. Apple
        // will default to "the only NEFilterDataProvider in the
        // app bundle" when this is nil, but future-proof
        // against ever shipping a second filter by pinning
        // the one we actually built.
        providerConfig.filterDataProviderBundleIdentifier = Self.extensionBundleIdentifier
        providerConfig.vendorConfiguration = serialize(
            policies: policies,
            vmBySourceIP: vmBySourceIP
        )

        manager.providerConfiguration = providerConfig
        manager.localizedDescription = Self.filterLocalizedDescription
        manager.isEnabled = true

        try await manager.saveToPreferences()
        Self.log.notice(
            "Applied \(policies.count) policy(ies) covering \(vmBySourceIP.count) VM source IP(s)"
        )
    }

    /// Removes the filter configuration entirely. System
    /// extension keeps running (operators approved it once);
    /// but with no config its `handleNewFlow` trivially
    /// allows every flow.
    public func removeAllPolicies() async throws {
        let manager = NEFilterManager.shared()
        try await manager.loadFromPreferences()
        manager.isEnabled = false
        manager.providerConfiguration = nil
        try await manager.saveToPreferences()
        Self.log.notice("Cleared NEFilterManager configuration")
    }

    // MARK: - Wire serialization

    /// Serializes the policy set into the `vendorConfiguration`
    /// dictionary the extension reads.
    ///
    /// ## Why JSONSerialization, not a Data blob
    ///
    /// `NEFilterProviderConfiguration.vendorConfiguration` is
    /// typed `[String: Any]?` and Apple's docs require the
    /// values to be property-list-compatible (String, Number,
    /// Bool, Date, Data, arrays, dictionaries keyed by
    /// String). Apple's sample code (SimpleFirewall,
    /// FilterControlProvider) stores **native dictionaries**
    /// directly — not opaque Data blobs — so operators can
    /// `defaults read` the saved configuration and inspect
    /// the policy structure without reaching for a decoder.
    ///
    /// The bridge from Codable → `[String: Any]` is
    /// [`JSONSerialization`](https://developer.apple.com/documentation/foundation/jsonserialization):
    ///
    /// 1. `JSONEncoder` serializes `FilterWireConfig` to
    ///    a canonical JSON byte stream (handles Dates,
    ///    optionality, tagged enums — things plain
    ///    property-list serialization can't).
    /// 2. `JSONSerialization.jsonObject(with:options:)`
    ///    parses that back into native Foundation types
    ///    (`NSDictionary`, `NSArray`, `NSString`,
    ///    `NSNumber`) — exactly the types
    ///    `vendorConfiguration` accepts.
    ///
    /// On the extension side the symmetric operation
    /// applies: `JSONSerialization.data(withJSONObject:)` →
    /// `JSONDecoder().decode(FilterWireConfig.self, from:)`.
    private func serialize(
        policies: [TenantEgressPolicy],
        vmBySourceIP: [String: (tenant: String, vmName: String)]
    ) -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        let wire = FilterWireConfig(
            version: 1,
            policies: policies,
            vmBySourceIP: vmBySourceIP.mapValues {
                FilterWireConfig.SourceIPMapping(
                    tenant: $0.tenant,
                    vmName: $0.vmName
                )
            }
        )

        guard let codableBlob = try? encoder.encode(wire),
              let nativeDict = try? JSONSerialization.jsonObject(
                with: codableBlob,
                options: []
              ) as? [String: Any] else {
            // Defensive fallback only: if encoding fails (which
            // means the wire types grew something non-Codable,
            // caught at dev time by round-trip tests), ship an
            // empty config so the extension treats every flow
            // as pass-through — fail-open is the right call
            // here because fail-closed would nuke every VM's
            // network on a bad deploy.
            Self.log.error("Policy serialization failed — shipping empty vendorConfiguration")
            return ["version": 1, "policies": [[String: Any]](), "vmBySourceIP": [String: Any]()]
        }
        return nativeDict
    }
}

/// Wire format shared between ``NEFilterConfigurator`` (host)
/// and `SpooktacularNetworkFilter`'s `NEFilterDataProvider`
/// subclass (extension).
///
/// Versioned (`version: 1` today) so the extension can
/// detect a schema mismatch and error out cleanly rather
/// than mis-parsing a newer host's blob.
public struct FilterWireConfig: Sendable, Codable, Equatable {
    public let version: Int
    public let policies: [TenantEgressPolicy]
    public let vmBySourceIP: [String: SourceIPMapping]

    public struct SourceIPMapping: Sendable, Codable, Equatable {
        public let tenant: String
        public let vmName: String

        public init(tenant: String, vmName: String) {
            self.tenant = tenant
            self.vmName = vmName
        }
    }

    public init(
        version: Int,
        policies: [TenantEgressPolicy],
        vmBySourceIP: [String: SourceIPMapping]
    ) {
        self.version = version
        self.policies = policies
        self.vmBySourceIP = vmBySourceIP
    }

    /// Decodes the config from the `Data` blob stored at
    /// `NEFilterProviderConfiguration.vendorConfiguration["policies"]`.
    /// The extension calls this during
    /// `NEFilterDataProvider.startFilter(completionHandler:)`.
    public static func decode(from data: Data) throws -> FilterWireConfig {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FilterWireConfig.self, from: data)
    }
}
