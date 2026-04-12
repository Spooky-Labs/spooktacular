import Foundation
import os

/// Resolves the IP address of a running VM by its MAC address.
///
/// The Virtualization framework assigns each VM a MAC address
/// (either random or explicit via ``VirtualMachineSpecification/macAddress``). When
/// the VM boots and obtains an IP via DHCP, the host's ARP table
/// and DHCP lease database contain the MAC-to-IP mapping.
///
/// `IPResolver` uses two strategies, tried in order:
///
/// 1. **DHCP leases** — Parses `/var/db/dhcpd_leases`, which
///    the macOS built-in DHCP server (used by NAT networking)
///    writes for every lease it grants. This is the most reliable
///    source for NAT-mode VMs.
///
/// 2. **ARP table** — Runs `arp -an` and parses the output for
///    the target MAC address. Works for bridged-mode VMs visible
///    on the host's LAN.
///
/// ## Usage
///
/// ```swift
/// let ip = try await IPResolver.resolveIP(macAddress: "aa:bb:cc:dd:ee:ff")
/// print(ip ?? "not found")
/// ```
///
/// ## Thread Safety
///
/// All methods are `async` and safe to call from any context.
/// The underlying `Process` calls are non-blocking.
public enum IPResolver {

    // MARK: - Public API

    /// Resolves the IP address of a running VM by its MAC address.
    ///
    /// Tries DHCP leases first, then falls back to the ARP table.
    ///
    /// - Parameter macAddress: The VM's MAC address as a
    ///   colon-separated hex string (e.g., `"aa:bb:cc:dd:ee:ff"`).
    ///   Case-insensitive.
    /// - Returns: The IPv4 address string, or `nil` if no mapping
    ///   was found.
    public static func resolveIP(macAddress: String) async throws -> String? {
        let normalizedMAC = macAddress.lowercased()
        Log.network.info("Resolving IP for MAC \(normalizedMAC)")

        // Strategy 1: DHCP lease file (best for NAT VMs)
        Log.network.debug("Trying DHCP leases for MAC \(normalizedMAC)")
        if let ip = try resolveFromLeases(macAddress: normalizedMAC) {
            Log.network.info("Resolved IP \(ip, privacy: .public) from DHCP leases for MAC \(normalizedMAC, privacy: .public)")
            return ip
        }

        // Strategy 2: ARP table (best for bridged VMs)
        Log.network.debug("Trying ARP table for MAC \(normalizedMAC)")
        if let ip = try await resolveFromARP(macAddress: normalizedMAC) {
            Log.network.info("Resolved IP \(ip, privacy: .public) from ARP table for MAC \(normalizedMAC, privacy: .public)")
            return ip
        }

        Log.network.info("No IP found for MAC \(normalizedMAC, privacy: .public)")
        return nil
    }

    // MARK: - DHCP Lease File

    /// The default path to the macOS DHCP server's lease database.
    ///
    /// The built-in DHCP server (used by VZNATNetworkDeviceAttachment)
    /// writes lease records to this plist-like file.
    public static let defaultLeaseFilePath = "/var/db/dhcpd_leases"

    /// Parses the DHCP lease file for a matching MAC address.
    ///
    /// The file uses a brace-delimited record format:
    /// ```
    /// {
    ///   ip_address=192.168.64.2
    ///   hw_address=1,aa:bb:cc:dd:ee:ff
    ///   ...
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - macAddress: Normalized (lowercased) MAC address.
    ///   - leaseFilePath: Path to the lease file. Defaults to
    ///     ``defaultLeaseFilePath``.
    /// - Returns: The IP address from the most recent matching
    ///   lease, or `nil` if not found.
    public static func resolveFromLeases(
        macAddress: String,
        leaseFilePath: String = defaultLeaseFilePath
    ) throws -> String? {
        guard let content = try? String(contentsOfFile: leaseFilePath, encoding: .utf8) else {
            return nil
        }
        return parseLeases(content, macAddress: macAddress)
    }

    /// Parses DHCP lease file content for a matching MAC address.
    ///
    /// Extracted as a separate method for testability.
    ///
    /// - Parameters:
    ///   - content: The raw text content of the lease file.
    ///   - macAddress: Normalized (lowercased) MAC address to find.
    /// - Returns: The IP address from the last matching lease
    ///   record, or `nil` if not found.
    public static func parseLeases(_ content: String, macAddress: String) -> String? {
        // Split into records delimited by { ... }
        let records = content.components(separatedBy: "}")

        var lastMatchIP: String?

        for record in records {
            var ip: String?
            var mac: String?

            for line in record.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("ip_address=") {
                    ip = String(trimmed.dropFirst("ip_address=".count))
                } else if trimmed.hasPrefix("hw_address=") {
                    // Format: "hw_address=1,aa:bb:cc:dd:ee:ff"
                    let value = String(trimmed.dropFirst("hw_address=".count))
                    // Strip the hardware type prefix (e.g., "1,")
                    if let commaIndex = value.firstIndex(of: ",") {
                        mac = String(value[value.index(after: commaIndex)...]).lowercased()
                    } else {
                        mac = value.lowercased()
                    }
                }
            }

            if let foundMAC = mac, let foundIP = ip, foundMAC == macAddress {
                lastMatchIP = foundIP
            }
        }

        return lastMatchIP
    }

    // MARK: - ARP Table

    /// Parses the system ARP table for a matching MAC address.
    ///
    /// Runs `arp -an` and searches the output for a line
    /// containing the target MAC address.
    ///
    /// - Parameter macAddress: Normalized (lowercased) MAC address.
    /// - Returns: The IP address from the ARP entry, or `nil`
    ///   if not found.
    public static func resolveFromARP(macAddress: String) async throws -> String? {
        let output = try await runProcess("/usr/sbin/arp", arguments: ["-an"])
        return parseARPOutput(output, macAddress: macAddress)
    }

    /// Parses `arp -an` output for a matching MAC address.
    ///
    /// Extracted as a separate method for testability. The expected
    /// format of each line is:
    /// ```
    /// ? (192.168.64.2) at aa:bb:cc:dd:ee:ff on bridge100 ifscope [bridge]
    /// ```
    ///
    /// - Parameters:
    ///   - output: The raw text output of `arp -an`.
    ///   - macAddress: Normalized (lowercased) MAC address to find.
    /// - Returns: The IP address from the matching ARP entry, or
    ///   `nil` if not found.
    public static func parseARPOutput(_ output: String, macAddress: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            let lowered = line.lowercased()
            guard lowered.contains(macAddress) else { continue }

            // Extract IP from between parentheses: "? (192.168.64.2) at ..."
            guard let openParen = line.firstIndex(of: "("),
                  let closeParen = line.firstIndex(of: ")"),
                  openParen < closeParen
            else {
                continue
            }

            let ip = String(line[line.index(after: openParen)..<closeParen])
            return ip
        }
        return nil
    }

    // MARK: - Process Execution

    /// Runs a process and returns its standard output as a string.
    ///
    /// - Parameters:
    ///   - path: The absolute path to the executable.
    ///   - arguments: Command-line arguments.
    /// - Returns: The process's standard output as a UTF-8 string.
    /// - Throws: An error if the process fails to launch.
    static func runProcess(
        _ path: String,
        arguments: [String]
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
