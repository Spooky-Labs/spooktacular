import Foundation

/// Wire protocol between the Spooktacular main app and the
/// bundled `SpooktacularVMHelper.xpc` helper process.
///
/// ## Why this exists
///
/// Today every VM's lifecycle (`VZVirtualMachine.start`,
/// `pause`, `stop`, `saveMachineStateTo`) runs inside the main
/// app's address space. A fatal error in one VM's rendering or
/// guest-agent handshake kills the GUI along with every other
/// running VM. Apple's sanctioned way to isolate a crash is a
/// bundled XPC service: the helper runs in its own `launchd`-
/// supervised process, so its failure surfaces as a broken
/// connection rather than a crashed app.
///
/// ## Scope
///
/// Track J lands in two shapes:
///
/// 1. **Session 1 (this commit).** ONE shared helper process
///    handles every VM. Main-app ↔ helper crash isolation is
///    the win; VMs still share a helper PID, so a crash in one
///    VM can still take siblings down. The XPC boundary + the
///    typed wire protocol are established, which is what later
///    tracks (H-Linux, L-QUIC) plug into.
/// 2. **Session 2+.** Shard to one helper PID per VM. Per-VM
///    crash isolation. Requires moving from shared-XPC-service
///    to `Process`-spawn-plus-anonymous-endpoint plumbing;
///    scoped as a follow-up because the protocol itself
///    doesn't change (the Mach service name is the only thing
///    that varies, per-VM).
///
/// ## Design constraints
///
/// - **`@objc` protocol, NSObject-compatible types only.**
///   `NSXPCInterface(with:)` requires an Obj-C-visible
///   protocol. All parameters are property-list compatible
///   (`String`, `NSNumber`, `Data`, `Bool`, or collections
///   thereof). VZ types never cross the wire — we pass VM
///   names (Strings) and shape lifecycle ops as verbs.
/// - **No reply?** All methods that mutate state use
///   completion handlers; the XPC dispatch is async by nature
///   and `NSXPCConnection` requires an explicit reply block
///   for any method whose result the caller depends on.
/// - **One optional-error reply.** Any method that can fail
///   delivers `Error?` as the last completion argument.
///   Success is `nil`; the caller branches on that.
///
/// ## References
///
/// - [NSXPCConnection](https://developer.apple.com/documentation/foundation/nsxpcconnection)
/// - [NSXPCInterface](https://developer.apple.com/documentation/foundation/nsxpcinterface)
/// - [Creating XPC services](https://developer.apple.com/documentation/xpc/creating-xpc-services)
@objc public protocol VMHelperProtocol {

    /// Liveness probe. Replies with the helper's PID and
    /// resolved bundle version so the main-app side can
    /// verify the boundary is up and diagnose which build of
    /// the helper is currently loaded.
    ///
    /// Shipped now (session 1) as the single verification
    /// call. Every future op follows the same shape: a
    /// `@Sendable` reply block is required because
    /// `NSXPCConnection` invokes completion blocks on an
    /// internal queue.
    @objc func ping(reply: @escaping @Sendable (_ pid: Int32, _ version: String) -> Void)
}

/// Mach service name the helper registers under. Must match:
///
/// - `CFBundleIdentifier` in the helper bundle's `Info.plist`
///   (`Resources/SpooktacularVMHelper-Info.plist`).
/// - The string passed to `NSXPCConnection(serviceName:)`
///   from the main-app-side client.
///
/// Declared in Core (alongside the protocol) so callers on
/// both sides of the wire read the same constant.
public enum VMHelperServiceName {
    /// Mach service name of the out-of-process VM helper XPC
    /// bundle. Matches `CFBundleIdentifier` in the helper's
    /// `Info.plist` and the `XPCService` `ServiceType` key.
    public static let helper = "com.spooktacular.app.VMHelper"
}
