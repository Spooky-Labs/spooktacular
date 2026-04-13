import os

/// Centralized loggers for SpooktacularKit.
///
/// Each category maps to a distinct area of the codebase,
/// making it easy to filter in Console.app or Instruments.
///
/// ## Filtering in Console.app
///
/// 1. Open Console.app
/// 2. Filter by Subsystem: `com.spooktacular`
/// 3. Narrow by Category: `vm`, `clone`, `ipsw`, `config`, etc.
///
/// ## Log Levels
///
/// | Level | When to use |
/// |-------|-------------|
/// | `.debug` | Verbose detail only useful during development |
/// | `.info` | Informational milestones (VM created, clone started) |
/// | `.notice` | Default level — notable events |
/// | `.error` | Recoverable errors (file not found, version mismatch) |
/// | `.fault` | Unrecoverable errors (should not happen in correct code) |
///
/// ## Privacy
///
/// String interpolation is redacted by default in production logs.
/// Use `privacy: .public` for values safe to show in Console.app
/// without a debugger (VM names, versions, file sizes).
/// Use `privacy: .private` (default) for paths, UUIDs, tokens.
public enum Log {

    /// The bundle identifier used as the logging subsystem.
    private static let subsystem = "com.spooktacular"

    /// VM lifecycle: create, start, stop, pause, resume, delete.
    public static let vm = Logger(subsystem: subsystem, category: "vm")

    /// VM configuration: building VZVirtualMachineConfiguration.
    public static let config = Logger(subsystem: subsystem, category: "config")

    /// Cloning: APFS clonefile, MachineIdentifier regeneration.
    public static let clone = Logger(subsystem: subsystem, category: "clone")

    /// IPSW management: download, cache, install.
    public static let ipsw = Logger(subsystem: subsystem, category: "ipsw")

    /// Compatibility checking: host vs image version.
    public static let compatibility = Logger(subsystem: subsystem, category: "compat")

    /// Networking: NAT, bridged, isolated.
    public static let network = Logger(subsystem: subsystem, category: "network")

    /// Provisioning: user-data, disk-inject, SSH, agent.
    public static let provision = Logger(subsystem: subsystem, category: "provision")

    /// Image library: cached IPSWs and OCI images.
    public static let images = Logger(subsystem: subsystem, category: "images")

    /// App UI: SwiftUI views, sheets, navigation.
    public static let ui = Logger(subsystem: subsystem, category: "ui")

    /// Snapshots: save, restore, list, delete disk-level snapshots.
    public static let snapshot = Logger(subsystem: subsystem, category: "snapshot")

    /// Capacity: concurrent VM limit enforcement.
    public static let capacity = Logger(subsystem: subsystem, category: "capacity")
}
