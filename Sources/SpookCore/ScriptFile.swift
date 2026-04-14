import Foundation

/// Writes executable shell scripts to temporary directories.
///
/// Used by template types (``GitHubRunnerTemplate``,
/// ``RemoteDesktopTemplate``, ``OpenClawTemplate``) to write
/// generated scripts to disk with correct permissions.
///
/// Each call creates a unique temporary directory to avoid
/// collisions when multiple VMs are provisioned concurrently.
///
/// ## Example
///
/// ```swift
/// let url = try ScriptFile.writeToTempDirectory(
///     script: "#!/bin/bash\necho hello",
///     fileName: "setup.sh"
/// )
/// // url -> /tmp/spooktacular-<uuid>/setup.sh
/// ```
public enum ScriptFile {

    /// Writes a shell script to a unique temporary directory.
    ///
    /// - Parameters:
    ///   - script: The shell script content.
    ///   - fileName: The file name for the script inside the
    ///     temporary directory.
    /// - Returns: The file URL of the written, executable script.
    /// - Throws: An error if the directory or file cannot be created.
    public static func writeToTempDirectory(
        script: String,
        fileName: String
    ) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spooktacular-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )

        let scriptURL = tempDir.appendingPathComponent(fileName)
        try Data(script.utf8).write(to: scriptURL, options: .atomic)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        return scriptURL
    }
}
