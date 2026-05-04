import Foundation

/// The result of a process execution on a guest VM.
///
/// Captures the exit code, standard output, and standard error
/// from a command run inside a guest virtual machine via the
/// node's guest-exec API.
public struct GuestExecResult: Sendable {

    /// The process exit code. Zero indicates success.
    public let exitCode: Int32

    /// The captured standard output of the process.
    public let stdout: String

    /// The captured standard error of the process.
    public let stderr: String

    /// Creates a new guest execution result.
    ///
    /// - Parameters:
    ///   - exitCode: The process exit code.
    ///   - stdout: The captured standard output.
    ///   - stderr: The captured standard error.
    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Abstracts communication with a Mac node running `spook serve`.
///
/// `NodeClient` defines the set of remote operations the controller
/// can perform against any node in the fleet. Implementations handle
/// the actual HTTP transport; consumers (such as ``RecycleStrategy``
/// implementations) program against this protocol so they can be
/// tested with a mock.
///
/// All methods are async and throwing — network failures, permission
/// errors, or node-side problems surface as thrown errors.
public protocol NodeClient: Sendable {

    /// Clones a VM from a source template on the given node.
    ///
    /// - Parameters:
    ///   - vm: The name for the new VM clone.
    ///   - source: The name of the source template VM.
    ///   - node: The endpoint URL of the node.
    func clone(vm: String, from source: String, on node: URL) async throws

    /// Starts a VM on the given node.
    ///
    /// - Parameters:
    ///   - vm: The name of the VM to start.
    ///   - node: The endpoint URL of the node.
    func start(vm: String, on node: URL) async throws

    /// Stops a VM on the given node.
    ///
    /// - Parameters:
    ///   - vm: The name of the VM to stop.
    ///   - node: The endpoint URL of the node.
    func stop(vm: String, on node: URL) async throws

    /// Deletes a VM on the given node.
    ///
    /// - Parameters:
    ///   - vm: The name of the VM to delete.
    ///   - node: The endpoint URL of the node.
    func delete(vm: String, on node: URL) async throws

    /// Restores a named snapshot for a VM on the given node.
    ///
    /// - Parameters:
    ///   - vm: The name of the VM.
    ///   - snapshot: The snapshot name to restore.
    ///   - node: The endpoint URL of the node.
    func restoreSnapshot(vm: String, snapshot: String, on node: URL) async throws

    /// Executes a command inside the guest VM and returns the result.
    ///
    /// - Parameters:
    ///   - vm: The name of the VM.
    ///   - command: The shell command to execute inside the guest.
    ///   - node: The endpoint URL of the node.
    /// - Returns: A ``GuestExecResult`` with exit code, stdout, and stderr.
    func execInGuest(vm: String, command: String, on node: URL) async throws -> GuestExecResult

    /// Checks whether a VM on the given node is healthy.
    ///
    /// - Parameters:
    ///   - vm: The name of the VM.
    ///   - node: The endpoint URL of the node.
    /// - Returns: `true` if the VM is healthy, `false` otherwise.
    func health(vm: String, on node: URL) async throws -> Bool
}
