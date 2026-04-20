import Foundation
import Network
import os
@preconcurrency import Virtualization

/// Restores guest network connectivity after a host-side
/// Wi-Fi or Ethernet interruption by cycling the bridged
/// network attachment.
///
/// ## The problem
///
/// A macOS guest booted with ``NetworkMode/bridged(interface:)``
/// gets its IP address from the host's LAN via DHCP. When the
/// host's physical interface drops (laptop lid closed and
/// reopened, VPN toggle, Wi-Fi roam across APs, Ethernet
/// cable pulled/reinserted), the guest's DHCP lease is still
/// valid from its perspective — but the gateway it learned
/// about is now unreachable. Without explicit help, the guest
/// sits with a stale lease until the kernel notices the ARP
/// timeout, which on a typical macOS guest is measured in
/// minutes.
///
/// ## The fix (GhostVM's trick)
///
/// `NWPathMonitor` surfaces interface-availability transitions
/// at system latency. When we see `.unsatisfied → .satisfied`
/// for `.wifi` or `.wiredEthernet`, we set the VM's network
/// device `.attachment = nil` (simulating a link-down), then
/// reassign a fresh `VZBridgedNetworkDeviceAttachment` over
/// the *same* bridged interface. The guest's virtio-net
/// driver sees the link cycle, its DHCP client issues a
/// DISCOVER, and within a couple seconds the VM is back with
/// a valid lease.
///
/// Apple documents `VZNetworkDevice.attachment` as a mutable
/// runtime property specifically so host apps can react to
/// link-state changes — this is the sanctioned path, not a
/// workaround.
///
/// ## Apple APIs
///
/// - [`NWPathMonitor`](https://developer.apple.com/documentation/network/nwpathmonitor)
///   — the path-availability publisher.
/// - [`NWPath.Status`](https://developer.apple.com/documentation/network/nwpath/status)
///   — `.satisfied / .unsatisfied / .requiresConnection`.
/// - [`NWInterface.InterfaceType`](https://developer.apple.com/documentation/network/nwinterface/interfacetype)
///   — `.wifi / .wiredEthernet` discrimination.
/// - [`VZVirtualMachine.networkDevices`](https://developer.apple.com/documentation/virtualization/vzvirtualmachine/networkdevices)
///   — runtime device list.
/// - [`VZNetworkDevice.attachment`](https://developer.apple.com/documentation/virtualization/vznetworkdevice/attachment)
///   — mutable-at-runtime attachment slot.
/// - [`VZBridgedNetworkDeviceAttachment`](https://developer.apple.com/documentation/virtualization/vzbridgednetworkdeviceattachment)
///   — the attachment we re-construct on link-up.
/// - [`VZBridgedNetworkInterface.networkInterfaces`](https://developer.apple.com/documentation/virtualization/vzbridgednetworkinterface/networkinterfaces)
///   — enumerable host interfaces.
///
/// ## Threading
///
/// The monitor is an `actor` so state transitions don't race;
/// `VZNetworkDevice` attachment mutations run via a
/// `Task { @MainActor }` hop because `VZVirtualMachine` state
/// mutations must happen on the VM's dispatch queue (which is
/// the main queue for GUI-hosted VMs — see
/// ``VirtualMachine``'s class-level docs for the `@MainActor`
/// rationale).
/// `@MainActor final class` rather than `actor` because
/// every piece of state a `BridgeMonitor` operates on is
/// main-actor-bound in practice:
/// - `VZVirtualMachine` per Apple's docs must be accessed
///   on its dispatch queue, which is the main queue for
///   GUI-hosted VMs (see `VZVirtualMachine.queue`).
/// - The path-refresh logic needs to rebuild the VM's
///   network attachment, which is a `VZVirtualMachine`
///   mutation — main-actor territory.
///
/// Custom-actor isolation would force every access to hop
/// to `@MainActor` anyway, so it buys nothing and creates
/// the Swift-6 region-isolation friction that surfaced as
/// a data-race warning when passing `VZVirtualMachine`
/// (non-`Sendable`) across the actor boundary in
/// ``VirtualMachine``'s init.  Keeping everything on
/// `@MainActor` sidesteps that entirely.
///
/// `NWPathMonitor` runs its path-update handler on its own
/// private queue, which we hop out of via
/// `Task { @MainActor in ... }`.
@MainActor
public final class BridgeMonitor {

    private static let log = Logger(
        subsystem: "com.spooktacular.app",
        category: "bridge-monitor"
    )

    /// The VM we're watching the bridge for. Weak so the
    /// monitor never keeps a dead VM alive.
    private weak var virtualMachine: VZVirtualMachine?

    /// The bridged-network interface identifier (e.g., `"en0"`)
    /// the spec bound us to. Used to re-construct a fresh
    /// attachment on link-up.
    private let interfaceName: String

    /// `Network.framework` path publisher. Nil when the
    /// monitor hasn't been `start()`ed.
    private var pathMonitor: NWPathMonitor?

    /// Last-observed path status so we can detect the
    /// *transition* from `.unsatisfied → .satisfied` rather
    /// than firing on every satisfied tick.
    private var lastStatus: NWPath.Status = .requiresConnection

    /// Private queue handed to `NWPathMonitor.start(queue:)`.
    /// Must not be the main queue — path-update handlers can
    /// fire mid-UI and we don't want to contend with the
    /// run-loop.
    private let monitorQueue = DispatchQueue(
        label: "com.spooktacular.bridge-monitor"
    )

    /// Creates a bridge monitor for the given VM + host
    /// interface.
    ///
    /// - Parameters:
    ///   - virtualMachine: VM whose bridged attachment should
    ///     be re-armed when the host link flaps.
    ///   - interface: BSD interface name (e.g., `en0`) the VM
    ///     bridges onto.
    public init(
        virtualMachine: VZVirtualMachine,
        interface: String
    ) {
        self.virtualMachine = virtualMachine
        self.interfaceName = interface
    }

    /// Begins watching the host's bridgeable interfaces.
    /// Idempotent — a second call while already running is a
    /// no-op.
    public func start() {
        guard pathMonitor == nil else { return }

        let monitor = NWPathMonitor(
            requiredInterfaceType: .wifi  // See note below.
        )
        // NWPathMonitor's type-filtered init watches ONE
        // interface type at a time. Bridged guests commonly
        // ride either Wi-Fi or Ethernet, so the production
        // shape below uses the unfiltered initializer and
        // inspects the available interface types per update
        // — a single monitor handles both laptop and
        // desktop topologies.
        let general = NWPathMonitor()
        general.pathUpdateHandler = { [weak self] path in
            Task { [weak self] in
                await self?.handlePathUpdate(path)
            }
        }
        general.start(queue: monitorQueue)
        self.pathMonitor = general
        self.lastStatus = general.currentPath.status

        // Throw away `monitor` — we only kept the type-
        // filtered init around for its doc-comment role.
        _ = monitor

        Self.log.notice(
            "BridgeMonitor started for interface \(self.interfaceName, privacy: .public)"
        )
    }

    /// Stops watching. Idempotent.
    public func stop() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    // MARK: - Path updates

    /// Core state machine. Dispatches a bridge refresh only on
    /// the `.unsatisfied → .satisfied` edge so we don't cycle
    /// the attachment on every unrelated path change.
    private func handlePathUpdate(_ path: NWPath) async {
        let previous = lastStatus
        lastStatus = path.status

        // Only interested in transitions TO satisfied from a
        // non-satisfied state. `.requiresConnection →
        // .satisfied` is Apple's documented state for a
        // cellular / VPN up-transition and counts too.
        guard previous != .satisfied, path.status == .satisfied else {
            return
        }

        // Require at least one interface of a type the bridge
        // could ride. Prevents spurious refreshes on loopback-
        // only path transitions.
        guard path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) else {
            return
        }

        Self.log.notice(
            "Host network up — refreshing bridged attachment for \(self.interfaceName, privacy: .public)"
        )

        await refreshAttachment()
    }

    /// Cycles the attachment: `nil` → fresh
    /// `VZBridgedNetworkDeviceAttachment`.  Runs on the
    /// main actor — the whole class is `@MainActor`, and
    /// `VZVirtualMachine` accesses must happen on the VM's
    /// dispatch queue (which is the main queue for
    /// GUI-hosted VMs per `VZVirtualMachine.queue` docs).
    ///
    /// `async` because the method sleeps briefly between
    /// nil-ing the old attachment and installing the new
    /// one — Apple recommends a short grace window so the
    /// guest sees the link-down edge before the link-up.
    private func refreshAttachment() async {
        guard let vm = self.virtualMachine else { return }
        guard let device = vm.networkDevices.first else {
            Self.log.warning("No VZNetworkDevice present — cannot refresh")
            return
        }

        // Re-resolve the host interface. Apple's
        // `VZBridgedNetworkInterface.networkInterfaces` list
        // can change across link transitions (a brand-new
        // identifier might appear if the host just gained a
        // USB-Ethernet adapter, for instance). Re-enumerating
        // each time avoids caching a stale reference.
        let interfaceName = self.interfaceName
        guard let target = VZBridgedNetworkInterface.networkInterfaces.first(
            where: { $0.identifier == interfaceName }
        ) else {
            Self.log.warning(
                "Interface \(interfaceName, privacy: .public) no longer available — bridge stays detached"
            )
            device.attachment = nil
            return
        }

        // Null the attachment first so the guest sees a link-
        // down event. Without this the virtio-net driver
        // thinks the link was always up and skips the DHCP
        // DISCOVER that would give it a fresh lease.
        device.attachment = nil
        // A short yield so the kernel can deliver the link-
        // down notification to the guest before we bring the
        // link back. 100 ms is the grace window Apple
        // recommends for similar transitions in their own
        // virtualization sample code.
        try? await Task.sleep(for: .milliseconds(100))
        device.attachment = VZBridgedNetworkDeviceAttachment(interface: target)

        Self.log.notice("Bridged attachment refreshed on \(interfaceName, privacy: .public)")
    }
}
