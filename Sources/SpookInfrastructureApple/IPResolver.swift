import Foundation
import SpookCore
import SpookApplication
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
/// let mac = MACAddress("aa:bb:cc:dd:ee:ff")!
/// let ip = try await IPResolver.resolveIP(macAddress: mac)
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
    /// - Parameter macAddress: The VM's MAC address.
    /// - Returns: The IPv4 address string, or `nil` if no mapping
    ///   was found.
    public static func resolveIP(macAddress: MACAddress) async throws -> String? {
        let normalizedMAC = macAddress.rawValue
        Log.network.info("Resolving IP for MAC \(normalizedMAC)")

        Log.network.debug("Trying DHCP leases for MAC \(normalizedMAC)")
        if let ip = try resolveFromLeases(macAddress: normalizedMAC) {
            Log.network.info("Resolved IP \(ip, privacy: .public) from DHCP leases for MAC \(normalizedMAC, privacy: .public)")
            return ip
        }

        Log.network.debug("Trying ARP table for MAC \(normalizedMAC)")
        if let ip = try await resolveFromARP(macAddress: normalizedMAC) {
            Log.network.info("Resolved IP \(ip, privacy: .public) from ARP table for MAC \(normalizedMAC, privacy: .public)")
            return ip
        }

        Log.network.info("No IP found for MAC \(normalizedMAC, privacy: .public)")
        return nil
    }

    // MARK: - Retry Loop

    /// Polls ``resolveIP(macAddress:)`` until the VM's IP address appears or the timeout expires.
    ///
    /// The VM needs time to boot and obtain a DHCP lease, so this
    /// method retries at the specified interval until the IP appears
    /// in the host's lease table or ARP cache.
    ///
    /// - Parameters:
    ///   - macAddress: The VM's MAC address.
    ///   - timeout: Maximum time to wait in seconds. Defaults to
    ///     120 seconds.
    ///   - pollInterval: Seconds between retries. Defaults to 5.
    /// - Returns: The resolved IPv4 address, or `nil` if the
    ///   timeout expires without a match.
    public static func resolveIPWithRetry(
        macAddress: MACAddress,
        timeout: TimeInterval = 120,
        pollInterval: TimeInterval = 5
    ) async throws -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        let sleepNanoseconds = UInt64(pollInterval * 1_000_000_000)

        while Date() < deadline {
            if let ip = try await resolveIP(macAddress: macAddress) {
                return ip
            }
            Log.provision.debug("IP not yet available for MAC \(macAddress.rawValue, privacy: .public), retrying in \(Int(pollInterval))s")
            try await Task.sleep(nanoseconds: sleepNanoseconds)
        }

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
        var lastMatchIP: String?

        for record in content.components(separatedBy: "}") {
            var ip: String?
            var mac: String?

            for line in record.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("ip_address=") {
                    ip = String(trimmed.dropFirst("ip_address=".count))
                } else if trimmed.hasPrefix("hw_address=") {
                    let value = String(trimmed.dropFirst("hw_address=".count))
                    if let commaIndex = value.firstIndex(of: ",") {
                        mac = String(value[value.index(after: commaIndex)...]).lowercased()
                    } else {
                        mac = value.lowercased()
                    }
                }
            }

            if mac == macAddress, let foundIP = ip {
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
        let output = try await ProcessRunner.runAsync("/usr/sbin/arp", arguments: ["-an"])
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
            guard line.lowercased().contains(macAddress),
                  let openParen = line.firstIndex(of: "("),
                  let closeParen = line.firstIndex(of: ")"),
                  openParen < closeParen
            else { continue }

            return String(line[line.index(after: openParen)..<closeParen])
        }
        return nil
    }

}
