import Foundation
import SpooktacularCore
import SpooktacularApplication
import os

/// A shared utility for spawning subprocesses and capturing their output.
///
/// Both ``IPResolver`` and ``DiskInjector`` need to run external tools
/// (`arp`, `hdiutil`, `diskutil`). `ProcessRunner` consolidates the
/// duplicated `Process` boilerplate into a single, tested location.
///
/// ## Usage
///
/// ```swift
/// // Synchronous (blocks the calling thread):
/// let output = try ProcessRunner.run("/usr/bin/hdiutil", arguments: ["info"])
///
/// // Asynchronous (safe from any async context):
/// let arpOutput = try await ProcessRunner.runAsync("/usr/sbin/arp", arguments: ["-an"])
/// ```
///
/// ## Thread Safety
///
/// ``run(_:arguments:)`` is synchronous and blocks until the process
/// exits. ``runAsync(_:arguments:)`` wraps the synchronous version
/// and is safe to call from any `async` context.
public enum ProcessRunner {

    /// Runs a process synchronously and returns its standard output.
    ///
    /// Standard error is captured alongside stdout (see
    /// [`Pipe`](https://developer.apple.com/documentation/foundation/pipe))
    /// so that on failure the caller receives both streams inside the
    /// thrown ``ProcessRunnerError/processFailed(command:stdout:stderr:exitCode:)``.
    /// Silently redirecting stderr to `/dev/null` hides the single most
    /// useful signal when `hdiutil attach` or `diskutil list` fails —
    /// with the output captured here, a test or an operator can pin
    /// the root cause without re-running with a debugger attached.
    ///
    /// - Parameters:
    ///   - executable: The absolute path to the executable.
    ///   - arguments: Command-line arguments.
    /// - Returns: The process's standard output as a UTF-8 string.
    /// - Throws: ``ProcessRunnerError/processFailed(command:stdout:stderr:exitCode:)``
    ///   if the process exits with a non-zero status.
    @discardableResult
    public static func run(
        _ executable: String,
        arguments: [String]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        // Reading from `fileHandleForReading` AFTER `waitUntilExit`
        // is safe for well-behaved CLI tools (`hdiutil`, `diskutil`,
        // `arp`) whose output fits in the pipe's kernel buffer.
        // If future callers need to run output-heavy binaries, move
        // to `readabilityHandler` for streaming.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let command = ([executable] + arguments).joined(separator: " ")
            Log.provision.error(
                "Process failed: \(command, privacy: .public) exit \(process.terminationStatus) stderr=\(stderr, privacy: .public)"
            )
            throw ProcessRunnerError.processFailed(
                command: command,
                stdout: stdout,
                stderr: stderr,
                exitCode: process.terminationStatus
            )
        }

        return stdout
    }

    /// Runs a process asynchronously and returns its standard output.
    ///
    /// This is a convenience wrapper around ``run(_:arguments:)``
    /// for use in `async` contexts.
    ///
    /// - Parameters:
    ///   - executable: The absolute path to the executable.
    ///   - arguments: Command-line arguments.
    /// - Returns: The process's standard output as a UTF-8 string.
    /// - Throws: ``ProcessRunnerError/processFailed(command:exitCode:)``
    ///   if the process exits with a non-zero status.
    public static func runAsync(
        _ executable: String,
        arguments: [String]
    ) async throws -> String {
        try run(executable, arguments: arguments)
    }
}

// MARK: - Errors

/// An error that occurs when a subprocess fails.
public enum ProcessRunnerError: Error, Sendable, Equatable, LocalizedError {

    /// A subprocess exited with a non-zero status.
    ///
    /// - Parameters:
    ///   - command: The command that was executed.
    ///   - stdout: UTF-8-decoded contents of the process's standard
    ///     output pipe.
    ///   - stderr: UTF-8-decoded contents of the process's standard
    ///     error pipe. Frequently the only useful diagnostic —
    ///     `hdiutil` / `diskutil` write failure reasons to stderr.
    ///   - exitCode: The process exit code.
    case processFailed(command: String, stdout: String, stderr: String, exitCode: Int32)

    public var errorDescription: String? {
        switch self {
        case .processFailed(let command, _, let stderr, let exitCode):
            let snippet = stderr
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(512)
            if snippet.isEmpty {
                return "Command failed with exit code \(exitCode): \(command)."
            }
            return "Command failed with exit code \(exitCode): \(command). stderr: \(snippet)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .processFailed:
            "Check that the command exists and is executable. "
            + "This operation requires running on a Mac with the expected system tools."
        }
    }
}
