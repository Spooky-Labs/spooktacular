import Foundation

/// Errors from privileged file operations.
public enum PrivilegedOpsError: Error, Equatable {
    /// The process lacks the root privilege required to set `root:wheel` ownership.
    case notPrivileged
}

/// Performs the root-owned file operations needed to inject a LaunchDaemon into
/// a guest volume: create directories and install files owned `root:wheel`.
public protocol PrivilegedFileOps: Sendable {
    /// Cheap check that privileged ops are possible; throws if not. Callers run
    /// this before expensive work (e.g. mounting a disk image) so a
    /// non-privileged run fails fast.
    func preflight() throws
    /// Creates `url` (and parents), owned `root:wheel`, mode 0755.
    func makeDirectory(at url: URL) throws
    /// Copies `src` to `dst`, then sets ownership `root:wheel` and the given mode.
    func installFile(from src: URL, to dst: URL, mode: mode_t) throws
}

/// `PrivilegedFileOps` for a process already running as root (EC2 Mac or under a
/// root LaunchDaemon). Throws ``PrivilegedOpsError/notPrivileged`` when not root.
public struct DirectPrivilegedFileOps: PrivilegedFileOps {
    private let effectiveUID: @Sendable () -> uid_t
    private let skipChownWhenNotRoot: Bool

    /// Creates the direct privileged file ops.
    /// - Parameters:
    ///   - effectiveUID: Seam for testing; defaults to `geteuid`.
    ///   - skipChownWhenNotRoot: When true, skips the real `chown(0,0)` if the
    ///     process isn't actually root (used by tests that stub `effectiveUID`).
    public init(
        effectiveUID: @escaping @Sendable () -> uid_t = { geteuid() },
        skipChownWhenNotRoot: Bool = false
    ) {
        self.effectiveUID = effectiveUID
        self.skipChownWhenNotRoot = skipChownWhenNotRoot
    }

    private func requireRoot() throws {
        guard effectiveUID() == 0 else { throw PrivilegedOpsError.notPrivileged }
    }

    public func preflight() throws { try requireRoot() }

    public func makeDirectory(at url: URL) throws {
        try requireRoot()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try chownRoot(url)
        try chmodPath(url, 0o755)
    }

    public func installFile(from src: URL, to dst: URL, mode: mode_t) throws {
        try requireRoot()
        if FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.removeItem(at: dst)
        }
        try FileManager.default.copyItem(at: src, to: dst)
        try chownRoot(dst)
        try chmodPath(dst, mode)
    }

    private func chownRoot(_ url: URL) throws {
        if skipChownWhenNotRoot && geteuid() != 0 { return }
        if chown(url.path, 0, 0) != 0 { throw posixError() }
    }

    private func chmodPath(_ url: URL, _ mode: mode_t) throws {
        if chmod(url.path, mode) != 0 { throw posixError() }
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
    }
}
