import Foundation

/// Builds and parses clipboard message payloads.
///
/// The four clipboard message types (`GRAB`, `REQUEST`, `DATA`,
/// `RELEASE`) share a common framing when
/// ``VDAgentCapability/clipboardSelection`` is negotiated:
/// every payload is prefixed with a 4-byte selection header
/// (1-byte selection ID + 3 reserved bytes). Our Mac guest
/// agent announces `clipboardSelection`, so every encode/decode
/// path here emits or expects that prefix.
public enum VDAgentClipboardMessage {

    /// Fixed width of the selection prefix (1 byte selection
    /// + 3 reserved bytes).
    static let selectionPrefixSize = 4

    // MARK: - GRAB

    /// "I have new clipboard data in these types, ask me for
    /// it if you want it." Sent on every copy in the guest,
    /// and received from the host on every host-side copy.
    public struct Grab: Equatable, Sendable {
        public var selection: VDAgentClipboardSelection
        /// Advertised types, in the sender's preference order.
        /// The receiver picks one when issuing a REQUEST.
        public var types: [VDAgentClipboardType]
        /// Serial number for resolving grab-grab races.
        /// Present when both peers negotiated
        /// ``VDAgentCapability/clipboardGrabSerial``.
        public var serial: UInt32?

        public init(
            selection: VDAgentClipboardSelection = .clipboard,
            types: [VDAgentClipboardType],
            serial: UInt32? = nil
        ) {
            self.selection = selection
            self.types = types
            self.serial = serial
        }

        public func encode() -> Data {
            var data = Data(
                capacity: selectionPrefixSize
                    + (serial == nil ? 0 : 4)
                    + types.count * 4
            )
            data.appendSelectionPrefix(selection)
            if let serial { data.appendLE(serial) }
            for type in types { data.appendLE(type.rawValue) }
            return data
        }

        /// Parses a grab payload. `hasSerial` must be set by
        /// the caller based on the negotiated capability set —
        /// the wire format doesn't self-describe presence of
        /// the serial field.
        public static func decode(
            payload: Data,
            hasSerial: Bool
        ) throws -> Self {
            let headerSize = selectionPrefixSize + (hasSerial ? 4 : 0)
            let selection = try payload.readSelectionPrefix(
                minimumLength: headerSize
            )
            let serial: UInt32? = hasSerial
                ? payload.readLE(UInt32.self, at: selectionPrefixSize)
                : nil

            let typeBytes = payload.count - headerSize
            guard typeBytes % 4 == 0 else {
                throw SpiceCodec.DecodeError.truncated(
                    expected: payload.count - (typeBytes % 4),
                    got: payload.count
                )
            }
            // Unknown clipboard types are silently skipped for
            // forward-compat with newer SPICE revisions.
            let types = (0..<(typeBytes / 4)).compactMap { i in
                VDAgentClipboardType(
                    rawValue: payload.readLE(
                        UInt32.self, at: headerSize + i * 4
                    )
                )
            }
            return Self(selection: selection, types: types, serial: serial)
        }
    }

    // MARK: - REQUEST

    /// "Send me the clipboard data of this type, please."
    public struct Request: Equatable, Sendable {
        public var selection: VDAgentClipboardSelection
        public var type: VDAgentClipboardType

        public init(
            selection: VDAgentClipboardSelection = .clipboard,
            type: VDAgentClipboardType
        ) {
            self.selection = selection
            self.type = type
        }

        public func encode() -> Data {
            var data = Data(capacity: selectionPrefixSize + 4)
            data.appendSelectionPrefix(selection)
            data.appendLE(type.rawValue)
            return data
        }

        public static func decode(payload: Data) throws -> Self {
            let selection = try payload.readSelectionPrefix(
                minimumLength: selectionPrefixSize + 4
            )
            let raw = payload.readLE(UInt32.self, at: selectionPrefixSize)
            guard let type = VDAgentClipboardType(rawValue: raw) else {
                throw SpiceCodec.DecodeError.unknownValue(
                    field: "clipboard type", raw: UInt64(raw)
                )
            }
            return Self(selection: selection, type: type)
        }
    }

    // MARK: - DATA

    /// The actual clipboard payload. `type` tells the receiver
    /// what's in `data` — raw UTF-8 bytes for text, a full
    /// PNG / BMP / TIFF / JPG file for images.
    public struct Payload: Equatable, Sendable {
        public var selection: VDAgentClipboardSelection
        public var type: VDAgentClipboardType
        public var data: Data

        public init(
            selection: VDAgentClipboardSelection = .clipboard,
            type: VDAgentClipboardType,
            data: Data
        ) {
            self.selection = selection
            self.type = type
            self.data = data
        }

        public func encode() -> Data {
            var result = Data(
                capacity: selectionPrefixSize + 4 + data.count
            )
            result.appendSelectionPrefix(selection)
            result.appendLE(type.rawValue)
            result.append(data)
            return result
        }

        public static func decode(payload: Data) throws -> Self {
            let headerSize = selectionPrefixSize + 4
            let selection = try payload.readSelectionPrefix(
                minimumLength: headerSize
            )
            let raw = payload.readLE(UInt32.self, at: selectionPrefixSize)
            guard let type = VDAgentClipboardType(rawValue: raw) else {
                throw SpiceCodec.DecodeError.unknownValue(
                    field: "clipboard type", raw: UInt64(raw)
                )
            }
            return Self(
                selection: selection,
                type: type,
                data: payload.subdata(in: headerSize..<payload.count)
            )
        }
    }

    // MARK: - RELEASE

    /// "My clipboard grab is no longer valid." Selection-only
    /// payload — 4 bytes total.
    public struct Release: Equatable, Sendable {
        public var selection: VDAgentClipboardSelection

        public init(selection: VDAgentClipboardSelection = .clipboard) {
            self.selection = selection
        }

        public func encode() -> Data {
            var data = Data(capacity: selectionPrefixSize)
            data.appendSelectionPrefix(selection)
            return data
        }

        public static func decode(payload: Data) throws -> Self {
            let selection = try payload.readSelectionPrefix(
                minimumLength: selectionPrefixSize
            )
            return Self(selection: selection)
        }
    }
}

// MARK: - Selection prefix helpers

private let selectionReservedBytes: [UInt8] = [0, 0, 0]

extension Data {
    /// Appends the 4-byte selection prefix shared by every
    /// clipboard message.
    mutating func appendSelectionPrefix(
        _ selection: VDAgentClipboardSelection
    ) {
        appendLE(selection.rawValue)
        append(contentsOf: selectionReservedBytes)
    }

    /// Validates payload length and decodes the leading
    /// selection byte. Throws if the payload is shorter than
    /// `minimumLength` or the selection byte is not a known
    /// ``VDAgentClipboardSelection``.
    func readSelectionPrefix(
        minimumLength: Int
    ) throws -> VDAgentClipboardSelection {
        guard count >= minimumLength else {
            throw SpiceCodec.DecodeError.truncated(
                expected: minimumLength, got: count
            )
        }
        let raw = readLE(UInt8.self, at: 0)
        guard let selection = VDAgentClipboardSelection(rawValue: raw) else {
            throw SpiceCodec.DecodeError.unknownValue(
                field: "clipboard selection", raw: UInt64(raw)
            )
        }
        return selection
    }
}
