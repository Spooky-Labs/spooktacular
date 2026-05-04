import Foundation
import SpooktacularCore

// Entry point for the bundled SpooktacularVMHelper XPC
// service. Packaged as `com.spooktacular.app.VMHelper.xpc`
// inside the main app's `Contents/XPCServices/`. `launchd`
// spawns this process on demand when the main app opens an
// `NSXPCConnection(serviceName:)` to the bundle identifier,
// and reaps it when the parent exits.
//
// ## Lifecycle
//
// 1. `NSXPCListener.service()` returns the listener `launchd`
//    pre-arms for this XPC service bundle. The listener
//    already has a valid Mach endpoint set up — we just wire
//    up the delegate + resume.
// 2. On each incoming connection, `ServiceDelegate` hands
//    back a `VMHelperImplementation` as the exported object.
//    Every method on `VMHelperProtocol` routes into that
//    instance on the connection's private queue.
// 3. `listener.resume()` *never returns*. The process lives
//    until `launchd` decides to recycle it (typically when
//    the parent exits or the helper has been idle).
//
// ## Why `NSXPCListener.service()` (not `.init(machServiceName:)`)
//
// `NSXPCListener.service()` is the sanctioned factory for
// bundled XPC services. It reads the already-established
// listener endpoint `launchd` set up when it launched this
// process — which means we do NOT register a new Mach name,
// so there's no chance of collision with a different app
// that happens to embed a helper with the same bundle ID.
// See [Apple's "Creating XPC services" guide](https://developer.apple.com/documentation/xpc/creating-xpc-services).
//
// ## Sandbox posture
//
// The helper's Info.plist sets `XPCService.ServiceType =
// Application` so the helper inherits the same App Sandbox
// container as the parent (see `Embedding a command-line
// tool in a sandboxed app`'s XPC-flavoured guidance). No
// extra entitlements are needed for the shared-helper
// shape in session 1; future per-VM sharding will revisit.

final class ServiceDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: VMHelperProtocol.self)
        newConnection.exportedObject = VMHelperImplementation()
        newConnection.resume()
        return true
    }
}

/// Exported object. One instance per accepted connection —
/// each client gets its own proxy receiver, which keeps
/// per-connection state (e.g. the set of VMs a client is
/// driving) isolated when we add real ops in later commits.
final class VMHelperImplementation: NSObject, VMHelperProtocol {
    func ping(reply: @escaping @Sendable (Int32, String) -> Void) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
        reply(pid, version)
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
