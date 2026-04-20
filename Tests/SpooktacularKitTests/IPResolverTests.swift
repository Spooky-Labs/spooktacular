import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpooktacularInfrastructureApple
@testable import SpooktacularApplication
@testable import SpooktacularCore

@Suite("IPResolver", .tags(.networking))
struct IPResolverTests {

    // MARK: - ARP Output Parsing

    @Suite("ARP table parsing")
    struct ARPParsingTests {

        @Test("finds IP for matching MAC in standard arp -an output", arguments: [
            (
                "? (192.168.64.2) at 11:22:33:44:55:66 on bridge100 ifscope [bridge]",
                "11:22:33:44:55:66",
                "192.168.64.2"
            ),
            (
                "? (10.0.0.5) at AA:BB:CC:DD:EE:FF on en0 ifscope [ethernet]",
                "aa:bb:cc:dd:ee:ff",
                "10.0.0.5"
            ),
            (
                """
                ? (192.168.64.1) at aa:bb:cc:dd:ee:ff on bridge100 ifscope [bridge]
                ? (192.168.64.2) at 11:22:33:44:55:66 on bridge100 ifscope [bridge]
                ? (10.0.0.1) at de:ad:be:ef:00:01 on en0 ifscope [ethernet]
                """,
                "11:22:33:44:55:66",
                "192.168.64.2"
            ),
        ] as [(String, String, String)])
        func findsMatchingMAC(output: String, mac: String, expectedIP: String) {
            let ip = IPResolver.parseARPOutput(output, macAddress: mac)
            #expect(ip == expectedIP)
        }

        @Test("returns nil when MAC is absent or entry is incomplete", arguments: [
            (
                "? (192.168.64.1) at aa:bb:cc:dd:ee:ff on bridge100 ifscope [bridge]",
                "00:00:00:00:00:00"
            ),
            (
                "",
                "aa:bb:cc:dd:ee:ff"
            ),
            (
                "incomplete at aa:bb:cc:dd:ee:ff on bridge100",
                "aa:bb:cc:dd:ee:ff"
            ),
        ] as [(String, String)])
        func returnsNil(output: String, mac: String) {
            let ip = IPResolver.parseARPOutput(output, macAddress: mac)
            #expect(ip == nil)
        }

        @Test("returns the first match when MAC appears on multiple interfaces")
        func multipleMatches() {
            let output = """
            ? (192.168.64.10) at aa:bb:cc:dd:ee:ff on bridge100 ifscope [bridge]
            ? (192.168.64.20) at aa:bb:cc:dd:ee:ff on bridge101 ifscope [bridge]
            """
            let ip = IPResolver.parseARPOutput(output, macAddress: "aa:bb:cc:dd:ee:ff")
            #expect(ip == "192.168.64.10")
        }

        @Test("skips lines with (incomplete) status marker")
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

        @Test("finds IP from lease entries with various formats", arguments: [
            (
                """
                {
                    name=my-vm
                    ip_address=192.168.64.3
                    hw_address=1,aa:bb:cc:dd:ee:ff
                    identifier=1,aa:bb:cc:dd:ee:ff
                    lease=0x67890123
                }
                """,
                "aa:bb:cc:dd:ee:ff",
                "192.168.64.3"
            ),
            (
                """
                {
                    ip_address=10.0.0.7
                    hw_address=aa:bb:cc:dd:ee:ff
                }
                """,
                "aa:bb:cc:dd:ee:ff",
                "10.0.0.7"
            ),
            (
                """
                {
                    ip_address=192.168.64.9
                    hw_address=1,AA:BB:CC:DD:EE:FF
                }
                """,
                "aa:bb:cc:dd:ee:ff",
                "192.168.64.9"
            ),
        ] as [(String, String, String)])
        func findsIPFromLease(content: String, mac: String, expectedIP: String) {
            let ip = IPResolver.parseLeases(content, macAddress: mac)
            #expect(ip == expectedIP)
        }

        @Test("returns nil when MAC is absent or content is empty", arguments: [
            (
                """
                {
                    ip_address=192.168.64.3
                    hw_address=1,11:22:33:44:55:66
                }
                """,
                "aa:bb:cc:dd:ee:ff"
            ),
            (
                "",
                "aa:bb:cc:dd:ee:ff"
            ),
        ] as [(String, String)])
        func returnsNil(content: String, mac: String) {
            let ip = IPResolver.parseLeases(content, macAddress: mac)
            #expect(ip == nil)
        }

        @Test("returns the last matching lease (most recent)")
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

        @Test("selects the correct MAC among multiple leases")
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
