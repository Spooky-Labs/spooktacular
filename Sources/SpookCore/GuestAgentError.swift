import Foundation

// MARK: - Guest Agent Errors

/// An error that occurs during guest agent communication.
///
/// Each case maps to a specific failure mode in the vsock-based
/// HTTP protocol between the host and the `spooktacular-agent` running
/// inside a guest VM.
///
/// ## Error Display
///
/// Every case provides both an ``errorDescription`` (what went wrong)
/// and a ``recoverySuggestion`` (what to do about it), following
/// Apple's `LocalizedError` pattern for actionable diagnostics.
public enum GuestAgentError: Error, Sendable, LocalizedError {

    /// The vsock connection could not be established.
    ///
    /// This typically means the guest has not finished booting,
    /// or the `spooktacular-agent` daemon is not installed.
    case notConnected

    /// The agent returned a non-2xx HTTP status code.
    ///
    /// - Parameters:
    ///   - statusCode: The HTTP status code from the agent.
    ///   - message: The error message from the agent's JSON body.
    case httpError(statusCode: Int, message: String)

    /// The response from the agent could not be parsed.
    ///
    /// This indicates a protocol mismatch between the host client
    /// and the guest agent version.
    case invalidResponse

    /// The agent did not respond within the expected time.
    case timeout

    /// Shell execution requires a break-glass token but none was configured.
    case breakGlassTokenRequired

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            "Cannot connect to the guest agent on the VirtIO socket."
        case .httpError(let statusCode, let message):
            "Guest agent returned HTTP \(statusCode): \(message)"
        case .invalidResponse:
            "The guest agent returned an unparseable response."
        case .timeout:
            "The guest agent did not respond in time."
        case .breakGlassTokenRequired:
            "Shell execution requires a break-glass token. Configure breakGlassToken on GuestAgentClient."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .notConnected:
            "Ensure the VM is running and spooktacular-agent is installed. "
            + "Run 'sudo spooktacular-agent --install-daemon' inside the guest."
        case .httpError:
            "Check the agent logs inside the guest for details."
        case .invalidResponse:
            "Update spooktacular-agent inside the guest to match this host version."
        case .timeout:
            "The guest may be under heavy load. Retry the operation, "
            + "or check that spooktacular-agent is running inside the VM."
        case .breakGlassTokenRequired:
            "Configure a break-glass token when creating GuestAgentClient: "
            + "GuestAgentClient(socketDevice: device, breakGlassToken: \"your-token\")"
        }
    }
}
