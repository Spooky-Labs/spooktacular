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

        // MARK: - Regression: unpadded hex octets (real host output)

        /// macOS's own `arp -an` formats each octet with a bare `%x`
        /// (not `%02x`) — an octet below `0x10` prints as one hex
        /// digit. Reproduced live: `arp -an` on this host prints the
        /// well-known `01:00:5e:00:00:fb` multicast MAC as
        /// `"1:0:5e:0:0:fb"`, and `"ee:f9:78:03:5a:04"` as
        /// `"ee:f9:78:3:5a:4"`. Before the fix, `parseARPOutput`
        /// compared the raw (unpadded) line text directly against
        /// ``SpooktacularCore/MACAddress/rawValue``, which is always
        /// fully zero-padded — so a real lookup for a MAC with any
        /// octet below `0x10` (roughly two-thirds of randomly
        /// generated addresses) silently returned `nil` even though
        /// the address was right there in the output. This exact
        /// mismatch caused a reproducible IP-resolution timeout in
        /// live `spook create --github-runner` end-to-end runs — see
        /// `plans/e2e-notes-2026-07.md`.
        @Test("finds IP when arp -an omits leading zeros on octets", arguments: [
            (
                "? (224.0.0.251) at 1:0:5e:0:0:fb on en0 ifscope permanent [ethernet]",
                "01:00:5e:00:00:fb",
                "224.0.0.251"
            ),
            (
                "? (192.168.1.40) at ee:f9:78:3:5a:4 on en0 ifscope [ethernet]",
                "ee:f9:78:03:5a:04",
                "192.168.1.40"
            ),
            (
                "? (192.168.64.2) at de:2a:2d:f3:1:b8 on bridge100 ifscope [bridge]",
                "de:2a:2d:f3:01:b8",
                "192.168.64.2"
            ),
        ] as [(String, String, String)])
        func findsMatchingMACWithUnpaddedOctets(output: String, mac: String, expectedIP: String) {
            let ip = IPResolver.parseARPOutput(output, macAddress: mac)
            #expect(ip == expectedIP)
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

        // MARK: - Regression: unpadded hex octets (real host output)

        /// `bootpd` writes `/var/db/dhcpd_leases`'s `hw_address=`
        /// field the same unpadded way `arp -an` does — confirmed by
        /// reading this host's real, live `dhcpd_leases` file during
        /// a `spook create --github-runner` reproduction: a guest
        /// assigned MAC `de:2a:2d:f3:01:b8` had its lease recorded as
        /// `hw_address=1,de:2a:2d:f3:1:b8` (octet `01` printed as a
        /// bare `1`). The lease was present and correct the entire
        /// time; ``IPResolver/parseLeases(_:macAddress:)``'s
        /// pre-fix exact-string comparison against the fully-padded
        /// ``SpooktacularCore/MACAddress/rawValue`` never matched
        /// it, so IP resolution timed out even though DHCP had
        /// already succeeded. See `plans/e2e-notes-2026-07.md` for
        /// the full live-run evidence.
        @Test("finds IP from lease entries with unpadded hex octets", arguments: [
            (
                """
                {
                    name=AppleViMachine1
                    ip_address=192.168.64.95
                    hw_address=1,de:2a:2d:f3:1:b8
                    identifier=1,de:2a:2d:f3:1:b8
                    lease=0x6a476323
                }
                """,
                "de:2a:2d:f3:01:b8",
                "192.168.64.95"
            ),
            (
                """
                {
                    name=AppleViMachine1
                    ip_address=192.168.64.96
                    hw_address=1,12:9e:3:38:c6:f
                    identifier=1,12:9e:3:38:c6:f
                    lease=0x6a476827
                }
                """,
                "12:9e:03:38:c6:0f",
                "192.168.64.96"
            ),
        ] as [(String, String, String)])
        func findsIPFromLeaseWithUnpaddedOctets(content: String, mac: String, expectedIP: String) {
            let ip = IPResolver.parseLeases(content, macAddress: mac)
            #expect(ip == expectedIP)
        }
    }

    // MARK: - MAC Normalization

    @Suite("MAC address normalization")
    struct NormalizationTests {

        @Test("pads bare hex digits and lowercases", arguments: [
            ("de:2a:2d:f3:1:b8", "de:2a:2d:f3:01:b8"),
            ("1:0:5e:0:0:fb", "01:00:5e:00:00:fb"),
            ("AA:BB:CC:DD:EE:FF", "aa:bb:cc:dd:ee:ff"),
            ("aa:bb:cc:dd:ee:ff", "aa:bb:cc:dd:ee:ff"),
        ] as [(String, String)])
        func normalizes(raw: String, expected: String) {
            #expect(IPResolver.normalizeMACAddress(raw) == expected)
        }

        @Test("rejects malformed input", arguments: [
            "not-a-mac",
            "aa:bb:cc:dd:ee",
            "aa:bb:cc:dd:ee:ff:11",
            "aa:bb:cc:dd:ee:gg",
            "",
        ])
        func rejectsMalformed(raw: String) {
            #expect(IPResolver.normalizeMACAddress(raw) == nil)
        }
    }
}
