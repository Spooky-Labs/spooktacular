import Foundation
import SpooktacularCore

/// A type that can report the current SPICE clipboard
/// bridge state. Injected into ``AgentHTTPServer`` at
/// startup by the guest-tools app (which owns the
/// `SpiceClipboardAgent` actor and its status stream).
///
/// The DTO types — ``SpooktacularCore/SpiceStatusSnapshot``
/// and ``SpooktacularCore/SpiceClipboardState`` — live in
/// `SpooktacularCore` so the host's `GuestAgentClient` can
/// decode them without depending on this library. This
/// package defines only the provider protocol, because
/// the guest-side composition (where an `AgentController`
/// adapts `SpiceAgentStatus` into a flat snapshot) is the
/// only concern left here.
public protocol SpiceStatusProvider: Sendable {
    /// Returns the current status snapshot. `async` so
    /// implementations backed by an actor can await the
    /// actor's isolation without blocking the HTTP request
    /// thread.
    func currentSpiceStatus() async -> SpiceStatusSnapshot
}
