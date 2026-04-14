import Foundation
import SpookCore
import SpookApplication
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
    /// - Parameters:
    ///   - executable: The absolute path to the executable.
    ///   - arguments: Command-line arguments.
    /// - Returns: The process's standard output as a UTF-8 string.
    /// - Throws: ``ProcessRunnerError/processFailed(command:exitCode:)``
    ///   if the process exits with a non-zero status.
    @discardableResult
    public static func run(
        _ executable: String,
        arguments: [String]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let command = ([executable] + arguments).joined(separator: " ")
            Log.provision.error("Process failed: \(command, privacy: .public) exit \(process.terminationStatus)")
            throw ProcessRunnerError.processFailed(
                command: command,
                exitCode: process.terminationStatus
            )
        }

        return output
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
    ///   - exitCode: The process exit code.
    case processFailed(command: String, exitCode: Int32)

    public var errorDescription: String? {
        switch self {
        case .processFailed(let command, let exitCode):
            "Command failed with exit code \(exitCode): \(command)."
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
