import Foundation
import Compression

/// Resolves `--from-image` arguments for Linux cloud images and handles
/// xz decompression.
///
/// Aliases resolve **at runtime** against the distro's official index —
/// never a hardcoded release:
///
/// - `fedora` → newest aarch64 `Cloud`/`Cloud_Base` `.raw.xz` listed in
///   <https://fedoraproject.org/releases.json>.
/// - `debian` → highest `debian-NN-genericcloud-arm64.raw` found by
///   walking release codenames from
///   <https://cloud.debian.org/images/cloud/> and probing each
///   `<codename>/latest/` listing (unreleased codenames have no
///   `latest/` and are skipped).
///
/// Local paths accept `.raw`, raw `.img`, and their `.xz`-compressed
/// forms. qcow2 (Ubuntu's cloud format) is rejected with a conversion
/// hint — the Virtualization framework consumes raw disks.
///
/// Networking is injected as a `fetch` closure so parsers are tested
/// against recorded fixtures and the CLI supplies a URLSession-backed
/// implementation.
public enum LinuxCloudImage {

    /// The outcome of resolving a `--from-image` argument.
    public enum Resolution: Equatable {
        /// A readable local image file.
        case localFile(URL, xzCompressed: Bool)
        /// A remote image to download (alias resolution).
        case download(url: URL, suggestedFileName: String, xzCompressed: Bool)
    }

    /// Resolves `argument` (alias or local path) to an image source.
    ///
    /// - Parameters:
    ///   - argument: `fedora`, `debian`, or a local file path.
    ///   - fetch: Returns the body at a URL, throwing on any
    ///     non-success (the Debian walk relies on this to skip
    ///     unreleased codenames).
    public static func resolve(
        _ argument: String,
        fetch: @Sendable (URL) async throws -> Data
    ) async throws -> Resolution {
        switch argument.lowercased() {
        case "fedora":
            guard let index = URL(string: "https://fedoraproject.org/releases.json") else {
                throw LinuxCloudImageError.badIndexURL
            }
            let url = try parseFedoraReleases(try await fetch(index))
            return .download(
                url: url,
                suggestedFileName: url.lastPathComponent,
                xzCompressed: true
            )
        case "debian":
            guard let index = URL(string: "https://cloud.debian.org/images/cloud/") else {
                throw LinuxCloudImageError.badIndexURL
            }
            let codenames = try parseDebianCodenames(try await fetch(index))
            var best: (release: Int, url: URL, fileName: String)?
            for codename in codenames {
                guard let listingURL = URL(string:
                    "https://cloud.debian.org/images/cloud/\(codename)/latest/") else { continue }
                guard let listing = try? await fetch(listingURL) else { continue }
                guard let parsed = parseDebianLatestListing(listing) else { continue }
                guard let fileURL = URL(string: parsed.fileName, relativeTo: listingURL) else { continue }
                if parsed.release > (best?.release ?? Int.min) {
                    best = (parsed.release, fileURL.absoluteURL, parsed.fileName)
                }
            }
            guard let best else {
                throw LinuxCloudImageError.indexParseFailed(
                    "debian cloud index (no released genericcloud-arm64 image found)"
                )
            }
            return .download(
                url: best.url,
                suggestedFileName: best.fileName,
                xzCompressed: false
            )
        default:
            let expanded = (argument as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded).standardizedFileURL
            let name = url.lastPathComponent.lowercased()
            if name.hasSuffix(".qcow2") {
                throw LinuxCloudImageError.qcow2Unsupported(url.path)
            }
            guard name.hasSuffix(".raw") || name.hasSuffix(".img")
                || name.hasSuffix(".raw.xz") || name.hasSuffix(".img.xz") else {
                throw LinuxCloudImageError.unsupportedFormat(url.path)
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw LinuxCloudImageError.fileNotFound(url.path)
            }
            return .localFile(url, xzCompressed: name.hasSuffix(".xz"))
        }
    }

    /// Picks the newest aarch64 Cloud-variant `.raw.xz` from Fedora's
    /// `releases.json` (a flat array of
    /// `{version, arch, variant, subvariant, link, …}`; the raw.xz
    /// cloud images carry `subvariant: Cloud_Base` in the recorded
    /// fixture).
    public static func parseFedoraReleases(_ json: Data) throws -> URL {
        struct Entry: Decodable {
            let version: String
            let arch: String
            let variant: String
            let subvariant: String?
            let link: String
        }
        let entries = try JSONDecoder().decode([Entry].self, from: json)
        let candidates = entries.filter {
            $0.arch == "aarch64"
                && $0.variant == "Cloud"
                && ($0.subvariant?.hasPrefix("Cloud_Base") ?? true)
                && $0.link.hasSuffix(".raw.xz")
        }
        let best = candidates.max {
            (Int($0.version) ?? 0) < (Int($1.version) ?? 0)
        }
        guard let best, let url = URL(string: best.link) else {
            throw LinuxCloudImageError.indexParseFailed("fedora releases.json")
        }
        return url
    }

    /// Extracts release-codename directories from Debian's cloud-image
    /// index HTML, excluding `sid` (unstable). Backports never match:
    /// the codename capture is letters-only, so `trixie-backports/`
    /// fails the trailing-slash match.
    public static func parseDebianCodenames(_ html: Data) throws -> [String] {
        guard let text = String(data: html, encoding: .utf8) else {
            throw LinuxCloudImageError.indexParseFailed("debian index (not utf8)")
        }
        let names = text.matches(of: /href="([a-z]+)\//)
            .map { String($0.output.1) }
        var seen = Set<String>()
        return names.filter { $0 != "sid" && seen.insert($0).inserted }
    }

    /// Finds `debian-NN-genericcloud-arm64.raw` in a
    /// `<codename>/latest/` directory listing. `nil` when the listing
    /// has no such artifact (pre-genericcloud releases).
    public static func parseDebianLatestListing(
        _ html: Data
    ) -> (release: Int, fileName: String)? {
        guard let text = String(data: html, encoding: .utf8) else { return nil }
        guard let match = text.firstMatch(of: /debian-([0-9]+)-genericcloud-arm64\.raw"/),
              let release = Int(match.output.1) else {
            return nil
        }
        return (release, "debian-\(release)-genericcloud-arm64.raw")
    }

    /// Streaming xz decode via the Compression framework.
    ///
    /// Apple documents `Algorithm.lzma` as "LZMA2 embedded in the XZ
    /// container — encoded buffers and streams … are valid `.xz`
    /// payloads", and the decoder accepts any compression level:
    /// <https://developer.apple.com/documentation/Compression/COMPRESSION_LZMA>.
    public static func decompressXZ(at src: URL, to dst: URL) throws {
        try filter(src: src, dst: dst, op: .decompress)
    }

    /// Test-only counterpart so the round-trip test needs no binary
    /// fixture; the framework's LZMA encoder emits valid xz.
    public static func compressXZForTesting(at src: URL, to dst: URL) throws {
        try filter(src: src, dst: dst, op: .compress)
    }

    private static func filter(src: URL, dst: URL, op: FilterOperation) throws {
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let output = try FileHandle(forWritingTo: dst)
        defer { try? output.close() }
        let outFilter = try OutputFilter(op, using: .lzma) { data in
            if let data { output.write(data) }
        }
        while true {
            let chunk = input.readData(ofLength: 1 << 20)
            try outFilter.write(chunk)
            if chunk.isEmpty { break }
        }
        try outFilter.finalize()
    }
}

/// Errors from ``LinuxCloudImage``.
public enum LinuxCloudImageError: Error, LocalizedError, Equatable {

    /// Internal: a hardwired index URL failed to construct.
    case badIndexURL

    /// A distro index/listing did not match the expected shape.
    case indexParseFailed(String)

    /// The local file extension is not a supported raw form.
    case unsupportedFormat(String)

    /// qcow2 images need conversion before use.
    case qcow2Unsupported(String)

    /// The local path does not exist.
    case fileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .badIndexURL:
            "Internal error: malformed distro index URL."
        case .indexParseFailed(let what):
            "Could not parse \(what) — the distro may have changed its index format."
        case .unsupportedFormat(let path):
            "Unsupported image format: \(path). Use a raw image (.raw or .img, optionally .xz-compressed)."
        case .qcow2Unsupported(let path):
            "\(path) is a qcow2 image. Convert it first: qemu-img convert -O raw <src> <dst>.raw (brew install qemu)."
        case .fileNotFound(let path):
            "Image not found at \(path)."
        }
    }
}
