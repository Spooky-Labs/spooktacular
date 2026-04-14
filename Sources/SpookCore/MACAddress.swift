import Foundation

/// A validated, normalized MAC address.
///
/// `MACAddress` guarantees its ``rawValue`` is always a lowercase,
/// colon-separated string of six hex pairs (e.g., `"02:ab:cd:ef:01:23"`).
/// Validation happens at initialization — if the input string does not
/// match the required format, `init(_:)` returns `nil`.
///
/// ## Creating a MAC Address
///
/// From a string:
///
/// ```swift
/// let mac = MACAddress("AA:BB:CC:DD:EE:FF")  // "aa:bb:cc:dd:ee:ff"
/// let bad = MACAddress("not-a-mac")           // nil
/// ```
///
/// Generating a random locally administered unicast address:
///
/// ```swift
/// let mac = MACAddress.generate()
/// print(mac) // e.g., "02:a3:f1:9c:44:b7"
/// ```
///
/// ## Codable
///
/// Encodes and decodes as a plain JSON string for maximum
/// compatibility with existing `config.json` files:
///
/// ```json
/// "macAddress": "02:ab:cd:ef:01:23"
/// ```
///
/// ## Thread Safety
///
/// `MACAddress` is `Sendable` and fully value-typed.
public struct MACAddress: Sendable, Codable, Equatable, Hashable, CustomStringConvertible {

    /// The normalized lowercase MAC address string in `xx:xx:xx:xx:xx:xx` format.
    public let rawValue: String

    /// Creates a MAC address from a string, validating format.
    ///
    /// The string must contain exactly six colon-separated hex pairs.
    /// The input is normalized to lowercase.
    ///
    /// - Parameter string: A MAC address string (e.g., `"AA:BB:CC:DD:EE:FF"`).
    /// - Returns: A validated `MACAddress`, or `nil` if the format is invalid.
    public init?(_ string: String) {
        let normalized = string.lowercased()
        let pattern = /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/
        guard normalized.wholeMatch(of: pattern) != nil else { return nil }
        self.rawValue = normalized
    }

    /// Generates a random locally administered unicast MAC address.
    ///
    /// The first octet has bit 1 (the "locally administered" bit) set
    /// and bit 0 (the multicast bit) cleared, producing addresses in
    /// the `02:xx:xx:xx:xx:xx` family. This ensures the address will
    /// not collide with any manufacturer-assigned (globally unique)
    /// MAC address.
    ///
    /// - Returns: A new random `MACAddress`.
    public static func generate() -> MACAddress {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] | 0x02) & 0xFE
        let string = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        return MACAddress(string)!
    }

    // MARK: - Codable

    /// Decodes a MAC address from a single string value.
    ///
    /// - Throws: `DecodingError.dataCorrupted` if the string is not
    ///   a valid MAC address.
    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let mac = MACAddress(string) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid MAC address: \(string)"
                )
            )
        }
        self = mac
    }

    /// Encodes the MAC address as a plain string.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    // MARK: - CustomStringConvertible

    /// The normalized MAC address string.
    public var description: String { rawValue }
}
