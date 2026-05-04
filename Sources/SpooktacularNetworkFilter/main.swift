import Foundation
import NetworkExtension

// System-extension entry point for the Spooktacular content
// filter.
//
// Lives as an `.executableTarget` but is packaged inside a
// `.systemextension` bundle by `build-app.sh`. The `.app`
// embeds the bundle under
// `Contents/Library/SystemExtensions/` and requests its
// activation via `OSSystemExtensionRequest`
// (see `SystemExtensionActivator` in the main app).
//
// This file intentionally does two and only two things:
//
//   1. `NEProvider.startSystemExtensionMode()` — tells the NE
//      runtime to set up the IPC channels the system uses to
//      invoke our `NEFilterDataProvider` subclass. Without
//      this call the system extension launches, sits idle,
//      and the filter never sees a flow.
//
//   2. `dispatchMain()` — parks the main thread on libdispatch
//      so the callbacks the NE runtime posts from its own
//      queue have a run-loop to land on. System extensions
//      aren't allowed to exit their main function; returning
//      from `main` would terminate the extension and the
//      kernel would tear the filter down.
//
// The principal class itself (`SpooktacularNetworkFilterProvider`,
// subclass of `NEFilterDataProvider`) is declared in
// `Sources/SpooktacularInfrastructureApple/SpooktacularNetworkFilterProvider.swift`
// and referenced by name in the extension's `Info.plist`
// under `NSExtension.NSExtensionPrincipalClass`. The
// Obj-C runtime resolves that string → `NEProvider.startSystemExtensionMode`
// instantiates one per filter activation.
//
// Apple references:
// - `NEProvider.startSystemExtensionMode()`
//   https://developer.apple.com/documentation/networkextension/neprovider/3188760-startsystemextensionmode
// - System Extensions framework
//   https://developer.apple.com/documentation/systemextensions
// - Configuring a Filter Provider extension (content-filter-provider-systemextension)
//   https://developer.apple.com/documentation/networkextension/filtering-network-traffic
//
// Import `SpooktacularInfrastructureApple` so the Swift linker
// pulls the `SpooktacularNetworkFilterProvider` symbol into
// this executable's image — otherwise the Obj-C runtime
// lookup done by `NSExtensionPrincipalClass` returns `nil`
// and the extension fails silently at activation time.
import SpooktacularInfrastructureApple

autoreleasepool {
    NEProvider.startSystemExtensionMode()
}

dispatchMain()
