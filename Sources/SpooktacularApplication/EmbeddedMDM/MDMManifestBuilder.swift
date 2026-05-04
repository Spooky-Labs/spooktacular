import Foundation
import CryptoKit

/// Produces the Apple-format application manifest plist that
/// `InstallEnterpriseApplication` points its `ManifestURL` at.
///
/// ## Wire shape
///
/// Apple documents this format in the iOS / macOS Enterprise
/// MDM Protocol Reference. It's the same plist
/// `OmniDiskSweeper` / `Sparkle` / etc. publish for over-the-
/// air installs:
///
/// ```
/// {
///   items: [
///     {
///       assets: [
///         {
///           kind: "software-package",
///           url: "https://.../my-userdata.pkg",
///           md5-size: <chunk size in bytes>,
///           md5s: [<base64 MD5s of each chunk>]
///         }
///       ]
///       metadata: {
///         kind: "software"
///         bundle-identifier: "com.spookylabs.userdata.<UUID>"
///         bundle-version: "1.0"
///         title: "User Data"
///       }
///     }
///   ]
/// }
/// ```
///
/// `mdmclient` validates the MD5 chunks against the downloaded
/// pkg bytes. Producing them requires the pkg in hand at
/// manifest-build time.
///
/// ## Why MD5 not SHA-256
///
/// Apple's manifest format is older than SHA-256 was
/// commonplace and has frozen on MD5 for the chunk hashes.
/// The use is integrity (detect download corruption / TLS-MITM
/// without an active modifying attacker), *not* security —
/// the chain of trust comes from the pkg's Developer ID
/// signature + notarization, not the manifest hashes. So
/// using MD5 here is acceptable; the security comes from the
/// pkg's signature (Phase 2 + the existing build pipeline).
public enum MDMManifestBuilder {

    /// Default chunk size for the `md5-size` field. 10 MiB
    /// matches what Apple uses in their iOS sample manifests.
    /// Smaller pkgs (under one chunk) just have a single
    /// MD5 in the array.
    public static let defaultChunkSize: Int = 10 * 1024 * 1024

    // MARK: - Public API

    /// Builds the manifest plist for a pkg located at the
    /// given URL. The URL must be reachable from the device —
    /// for the embedded MDM that's the host's manifest server.
    ///
    /// - Parameters:
    ///   - pkgData: The raw bytes of the .pkg. Used to compute
    ///     the chunk MD5s.
    ///   - pkgURL: Where the device should fetch the pkg from.
    ///     The manifest's `assets[0].url` field is set to this.
    ///   - bundleIdentifier: A unique-per-pkg ID. For user-data
    ///     pkgs the convention is
    ///     `com.spookylabs.userdata.<random UUID>` so a host
    ///     pushing the same script to many VMs doesn't get
    ///     `mdmclient` short-circuiting on "already installed".
    ///   - bundleVersion: Free-form. `1.0` is fine for
    ///     one-shot user-data pkgs that aren't updated.
    ///   - title: Human-readable title; surfaces in the
    ///     device's "installing…" banner. We use "Spooktacular
    ///     Provisioning" for user-data scripts.
    ///   - chunkSize: Override for ``defaultChunkSize``. Tests
    ///     pin a smaller value to exercise the multi-chunk
    ///     path.
    /// - Returns: XML-format plist data ready to serve over
    ///   the manifest endpoint.
    public static func build(
        pkgData: Data,
        pkgURL: URL,
        bundleIdentifier: String,
        bundleVersion: String = "1.0",
        title: String = "Spooktacular Provisioning",
        chunkSize: Int = defaultChunkSize
    ) throws -> Data {
        let md5s = chunkMD5s(of: pkgData, chunkSize: chunkSize)
        let asset: [String: Any] = [
            "kind": "software-package",
            "url": pkgURL.absoluteString,
            "md5-size": chunkSize,
            "md5s": md5s
        ]
        let metadata: [String: Any] = [
            "kind": "software",
            "bundle-identifier": bundleIdentifier,
            "bundle-version": bundleVersion,
            "title": title
        ]
        let item: [String: Any] = [
            "assets": [asset],
            "metadata": metadata
        ]
        let root: [String: Any] = [
            "items": [item]
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .xml,
            options: 0
        )
    }

    // MARK: - Internal — chunk MD5s

    /// Splits the pkg into `chunkSize`-byte slices and returns
    /// the lowercase-hex MD5 of each. The last chunk is just
    /// the remainder, however small.
    static func chunkMD5s(of data: Data, chunkSize: Int) -> [String] {
        guard chunkSize > 0 else { return [] }
        var hashes: [String] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let slice = data[offset..<end]
            let digest = Insecure.MD5.hash(data: slice)
            hashes.append(digest.map { String(format: "%02x", $0) }.joined())
            offset = end
        }
        return hashes
    }
}
