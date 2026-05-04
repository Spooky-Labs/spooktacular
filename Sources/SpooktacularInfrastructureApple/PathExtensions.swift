import Foundation

// MARK: - Tilde expansion

public extension String {

    /// Expands a leading `~` to the current user's home directory.
    ///
    /// Swift Foundation does not ship a first-party tilde-expansion
    /// helper, which is why the pre-refactor codebase reached for
    /// `NSString(string: self).expandingTildeInPath` at every
    /// call site. Those bridges into ObjC Foundation aren't free
    /// and leak into operators' profilers. This helper collapses
    /// the pattern to one line:
    ///
    /// ```swift
    /// "~/Library/LaunchAgents".expandingTilde
    /// // → "/Users/jdoe/Library/LaunchAgents"
    /// ```
    ///
    /// Only the leading `~` is expanded — embedded `~` elsewhere
    /// in the path is left alone, matching POSIX shell behavior
    /// for the common `~` / `~/` prefix cases. Non-tilde paths
    /// pass through unchanged.
    ///
    /// - Returns: The path with the leading `~` replaced by the
    ///   current user's home directory, or the original string if
    ///   there is no leading tilde.
    var expandingTilde: String {
        guard hasPrefix("~") else { return self }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if self == "~" { return home }
        if hasPrefix("~/") {
            return home + dropFirst()  // drops only the "~", keeps the "/…"
        }
        // A path like "~username/..." is uncommon and the Swift API
        // can't resolve it without `getpwnam`. Leave it alone — the
        // operator gets a clear "file not found" rather than a
        // silently-wrong expansion.
        return self
    }
}

// MARK: - URL convenience

public extension URL {

    /// The parent directory's path as a `String`.
    ///
    /// Shorthand for `deletingLastPathComponent().path` that reads
    /// cleaner at call sites which already hold a `URL` and just
    /// need the directory path for `FileManager` APIs. Replaces the
    /// pre-refactor `(path as NSString).deletingLastPathComponent`
    /// idiom — which bridged into `NSString` every call.
    var parentPath: String {
        deletingLastPathComponent().path
    }
}
