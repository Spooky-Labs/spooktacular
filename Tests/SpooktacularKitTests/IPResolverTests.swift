import Testing
import Foundation
@testable import SpooktacularKit

@Suite("IPResolver")
struct IPResolverTests {

    // MARK: - ARP Output Parsing

    @Suite("ARP table parsing")
    struct ARPParsingTests {

        @Test("Finds IP for a matching MAC address in standard arp -an output")
        func findsMatchingMAC() {
            let output = """
            ? (192.168.64.1) at aa:bb:cc:dd:ee:ff on bridge100 ifscope [bridge]
            ? (192.168.64.2) at 11:22:33:44:55:66 on bridge100 ifscope [bridge]
            ? (10.0.0.1) at de:ad:be:ef:00:01 on en0 ifscope [ethernet]
            """
            let ip = IPResolver.parseARPOutput(output, macAddress: "11:22:33:44:55:66")
            #expect(ip == "192.168.64.2")
        }

        @Test("Returns nil when MAC is not in the ARP table")
        func noMatch() {
            let output = """
            ? (192.168.64.1) at aa:bb:cc:dd:ee:ff on bridge100 ifscope [bridge]
            """
            let ip = IPResolver.parseARPOutput(output, macAddress: "00:00:00:00:00:00")
            #expect(ip == nil)
        }

        @Test("Returns nil for empty ARP output")
        func emptyOutput() {
            let ip = IPResolver.parseARPOutput("", macAddress: "aa:bb:cc:dd:ee:ff")
            #expect(ip == nil)
        }

        @Test("Case-insensitive MAC matching")
        func caseInsensitive() {
            let output = """
            ? (10.0.0.5) at AA:BB:CC:DD:EE:FF on en0 ifscope [ethernet]
            """
            let ip = IPResolver.parseARPOutput(output, macAddress: "aa:bb:cc:dd:ee:ff")
            #expect(ip == "10.0.0.5")
        }

        @Test("Handles incomplete entry without parentheses gracefully")
        func incompleteEntry() {
            let output = """
            incomplete at aa:bb:cc:dd:ee:ff on bridge100
            """
            let ip = IPResolver.parseARPOutput(output, macAddress: "aa:bb:cc:dd:ee:ff")
            #expect(ip == nil)
        }

        @Test("Handles multiple entries and returns the first match")
        func multipleMatches() {
            let output = """
            ? (192.168.64.10) at aa:bb:cc:dd:ee:ff on bridge100 ifscope [bridge]
            ? (192.168.64.20) at aa:bb:cc:dd:ee:ff on bridge101 ifscope [bridge]
            """
            let ip = IPResolver.parseARPOutput(output, macAddress: "aa:bb:cc:dd:ee:ff")
            #expect(ip == "192.168.64.10")
        }

        @Test("Skips lines with (incomplete) status")
        func incompleteStatus() {
            let output = """
            ? (192.168.64.1) at (incomplete) on bridge100 ifscope [bridge]
            ? (192.168.64.2) at aa:bb:cc:dd:ee:ff on bridge100 ifscope [bridge]
            """
            let ip = IPResolver.parseARPOutput(output, macAddress: "aa:bb:cc:dd:ee:ff")
            #expect(ip == "192.168.64.2")
        }
    }

    // MARK: - DHCP Lease Parsing

    @Suite("DHCP lease file parsing")
    struct LeaseParsingTests {

        @Test("Finds IP from a standard DHCP lease file")
        func findsIPFromLease() {
            let content = """
            {
                name=my-vm
                ip_address=192.168.64.3
                hw_address=1,aa:bb:cc:dd:ee:ff
                identifier=1,aa:bb:cc:dd:ee:ff
                lease=0x67890123
            }
            """
            let ip = IPResolver.parseLeases(content, macAddress: "aa:bb:cc:dd:ee:ff")
            #expect(ip == "192.168.64.3")
        }

        @Test("Returns nil when MAC is not in any lease")
        func noMatchingLease() {
            let content = """
            {
                ip_address=192.168.64.3
                hw_address=1,11:22:33:44:55:66
            }
            """
            let ip = IPResolver.parseLeases(content, macAddress: "aa:bb:cc:dd:ee:ff")
            #expect(ip == nil)
        }

        @Test("Returns nil for empty lease file content")
        func emptyContent() {
            let ip = IPResolver.parseLeases("", macAddress: "aa:bb:cc:dd:ee:ff")
            #expect(ip == nil)
        }

        @Test("Returns the last matching lease (most recent)")
        func lastMatchWins() {
            let content = """
            {
                ip_address=192.168.64.2
                hw_address=1,aa:bb:cc:dd:ee:ff
            }
            {
                ip_address=192.168.64.5
                hw_address=1,aa:bb:cc:dd:ee:ff
            }
            """
            let ip = IPResolver.parseLeases(content, macAddress: "aa:bb:cc:dd:ee:ff")
            #expect(ip == "192.168.64.5")
        }

        @Test("Handles MAC without hardware type prefix")
        func noHardwareTypePrefix() {
            let content = """
            {
                ip_address=10.0.0.7
                hw_address=aa:bb:cc:dd:ee:ff
            }
            """
            let ip = IPResolver.parseLeases(content, macAddress: "aa:bb:cc:dd:ee:ff")
            #expect(ip == "10.0.0.7")
        }

        @Test("Case-insensitive MAC matching in leases")
        func caseInsensitive() {
            let content = """
            {
                ip_address=192.168.64.9
                hw_address=1,AA:BB:CC:DD:EE:FF
            }
            """
            let ip = IPResolver.parseLeases(content, macAddress: "aa:bb:cc:dd:ee:ff")
            #expect(ip == "192.168.64.9")
        }

        @Test("Multiple leases with different MACs finds correct one")
        func correctMAC() {
            let content = """
            {
                ip_address=192.168.64.2
                hw_address=1,11:22:33:44:55:66
            }
            {
                ip_address=192.168.64.3
                hw_address=1,aa:bb:cc:dd:ee:ff
            }
            {
                ip_address=192.168.64.4
                hw_address=1,de:ad:be:ef:00:01
            }
            """
            let ip = IPResolver.parseLeases(content, macAddress: "aa:bb:cc:dd:ee:ff")
            #expect(ip == "192.168.64.3")
        }
    }
}
