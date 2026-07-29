import Foundation

/// A VM's link to the shared, read-only base image it was created from.
///
/// A VM's overlay is only meaningful on top of the exact base layer it
/// was stacked onto. DiskImageKit enforces that itself through
/// `parentUUID` lineage, but recording the expected ``layerUUID`` here
/// lets Spooktacular fail with an actionable message — "the base image
/// changed since this VM was created" — instead of surfacing a raw
/// framework error.
public struct BaseImageReference: Sendable, Codable, Equatable {

    /// The macOS build the base was installed from, for example `27A5301a`.
    public let buildVersion: String

    /// The base layer's UUID at the time this VM was created.
    public let layerUUID: UUID

    /// Creates a reference to a base image.
    ///
    /// - Parameters:
    ///   - buildVersion: The macOS build string of the base.
    ///   - layerUUID: The base layer's DiskImageKit layer UUID.
    public init(buildVersion: String, layerUUID: UUID) {
        self.buildVersion = buildVersion
        self.layerUUID = layerUUID
    }
}
