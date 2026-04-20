import Foundation

/// The guest operating system that a ``VirtualMachineSpecification``
/// targets. Added in Track H when Linux guest support shipped;
/// pre-Track-H bundles that don't carry this field decode as
/// ``GuestOS/macOS``.
///
/// ## Why an enum, not a Bool
///
/// The infrastructure layer branches on this to choose radically
/// different Apple APIs:
///
/// | Concern | `.macOS` | `.linux` |
/// |---|---|---|
/// | Boot loader | `VZMacOSBootLoader` | `VZEFIBootLoader` (+ `VZEFIVariableStore`) |
/// | Platform | `VZMacPlatformConfiguration` (hardware model, machine ID, aux storage) | `VZGenericPlatformConfiguration` |
/// | Keyboard | `VZMacKeyboardConfiguration` | `VZUSBKeyboardConfiguration` |
/// | Pointing device | `VZMacTrackpadConfiguration` | `VZUSBScreenCoordinatePointingDeviceConfiguration` |
/// | Graphics | `VZMacGraphicsDeviceConfiguration` + `VZMacGraphicsDisplayConfiguration` | `VZVirtioGraphicsDeviceConfiguration` + `VZVirtioGraphicsScanoutConfiguration` |
/// | USB controller | Not required (Mac I/O paths don't go through XHCI) | Required — `VZXHCIControllerConfiguration` hosts the USB keyboard/mouse/mass-storage stack |
///
/// A boolean would obscure the fact that these aren't orthogonal
/// switches but rather two entirely distinct device graphs. The
/// enum forces the infrastructure layer to handle both cases
/// exhaustively at compile time.
///
/// ## Apple references
///
/// - [Creating and Running a Linux Virtual Machine](https://developer.apple.com/documentation/virtualization/creating-and-running-a-linux-virtual-machine)
/// - [VZGenericPlatformConfiguration](https://developer.apple.com/documentation/virtualization/vzgenericplatformconfiguration)
/// - [VZEFIBootLoader](https://developer.apple.com/documentation/virtualization/vzefibootloader)
public enum GuestOS: Sendable, Codable, Equatable, Hashable {

    /// A macOS guest. Uses `VZMacOSBootLoader` +
    /// `VZMacPlatformConfiguration` and requires the Mac-
    /// specific input/display peripherals. This is the default
    /// when a bundle's `config.json` doesn't carry a
    /// `guestOS` field (pre-Track-H bundles).
    case macOS

    /// A Linux guest. Uses `VZEFIBootLoader` +
    /// `VZGenericPlatformConfiguration` and requires USB
    /// keyboard/mouse + virtio graphics. Rosetta support
    /// (`VZLinuxRosettaDirectoryShare`) is handled in a
    /// separate pass after session 1's config-branching
    /// lands.
    case linux

    /// Whether this guest OS places a floor on the minimum
    /// CPU count. macOS requires ≥4 cores to boot without
    /// hanging on Apple Silicon (the
    /// ``VirtualMachineSpecification/minimumCPUCount``
    /// constant); Linux has no such floor and can run on a
    /// single core.
    public var minimumCPUCount: Int {
        switch self {
        case .macOS: return 4
        case .linux: return 1
        }
    }
}
