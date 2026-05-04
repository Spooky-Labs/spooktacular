import Foundation

/// A per-workspace icon specification.
///
/// ``IconSpec`` describes how Spooktacular should render the Dock /
/// library / app-switcher icon for a single VM. It lives in the
/// domain layer so the CLI, the SwiftUI app, and a future web UI can
/// all read and write the same format. The actual ``NSImage``
/// composition happens in the infrastructure layer
/// (`WorkspaceIconRenderer`).
///
/// ## Modes
///
/// - ``cloneApp(bundleID:)`` — reuse a known macOS app's icon
///   (`"com.apple.Safari"`, `"com.microsoft.VSCode"`, etc.). The
///   renderer looks the app up via `NSWorkspace.urlForApplication`.
/// - ``stack(top:bottom:)`` — overlay two SF Symbols, the top symbol
///   at 70% size in the bottom-right corner of the bottom symbol.
/// - ``glassFrame(symbol:tint:)`` — a Liquid Glass rounded square
///   containing one SF Symbol, tinted to the given hue.
/// - ``preset(name:)`` — one of Spooktacular's shipped artwork
///   presets (PNGs in the app bundle). `name` is a stable string
///   key: `"xcode"`, `"ios-sim"`, `"runner"`, etc.
///
/// ## JSON shape
///
/// Stored as a discriminated union. Missing/unknown modes decode as
/// `nil` — callers should substitute the default icon.
///
/// ```json
/// {"mode": "glassFrame", "symbol": "hammer.fill", "tint": "blue"}
/// {"mode": "stack", "top": "gearshape.fill", "bottom": "macpro.gen3"}
/// {"mode": "cloneApp", "bundleID": "com.microsoft.VSCode"}
/// {"mode": "preset", "name": "runner"}
/// ```
public enum IconSpec: Sendable, Codable, Equatable, Hashable {

    /// Reuse an installed macOS app's icon by bundle identifier.
    ///
    /// - Parameter bundleID: A reverse-DNS identifier like
    ///   `"com.apple.Safari"` or `"com.microsoft.VSCode"`. If the
    ///   app is not installed, the renderer falls back to
    ///   ``IconSpec/defaultSpec``.
    case cloneApp(bundleID: String)

    /// Overlay two SF Symbols to compose a custom icon.
    ///
    /// - Parameters:
    ///   - top: Foreground symbol painted in the lower-right.
    ///   - bottom: Background symbol painted full-frame.
    case stack(top: String, bottom: String)

    /// Paint an SF Symbol inside a Liquid Glass rounded square.
    ///
    /// - Parameters:
    ///   - symbol: An SF Symbol name.
    ///   - tint: A semantic tint. Interpreted by the renderer.
    case glassFrame(symbol: String, tint: Tint)

    /// Use one of the built-in artwork presets.
    ///
    /// - Parameter name: A stable preset identifier. See
    ///   ``IconSpec/builtInPresetNames`` for the shipped set.
    case preset(name: String)

    // MARK: - Tint

    /// Semantic tints supported by ``glassFrame(symbol:tint:)``.
    ///
    /// Concrete colors are resolved by the renderer so the domain
    /// layer can stay dependency-free (no `NSColor` / `Color`).
    public enum Tint: String, Sendable, Codable, Equatable, Hashable {
        case accent
        case blue
        case purple
        case pink
        case red
        case orange
        case yellow
        case green
        case teal
        case mono
    }

    // MARK: - Defaults

    /// The icon used when no ``IconSpec`` is set or one fails to
    /// render: a ghost symbol inside a glass frame tinted with the
    /// system accent color. Always resolves.
    public static let defaultSpec: IconSpec = .glassFrame(
        symbol: "apparel.fill",
        tint: .accent
    )

    /// Names of presets shipped with Spooktacular.
    ///
    /// Matches image-set names in the SwiftUI app's asset catalog.
    /// Callers can use this for a preset picker UI.
    public static let builtInPresetNames: [String] = [
        "xcode",
        "ios-sim",
        "runner",
        "jenkins",
        "mdm",
        "desktop",
        "spook",
    ]

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case mode
        case bundleID
        case top
        case bottom
        case symbol
        case tint
        case name
    }

    private enum Mode: String, Codable {
        case cloneApp
        case stack
        case glassFrame
        case preset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decode(Mode.self, forKey: .mode)
        switch mode {
        case .cloneApp:
            self = .cloneApp(
                bundleID: try container.decode(String.self, forKey: .bundleID)
            )
        case .stack:
            self = .stack(
                top: try container.decode(String.self, forKey: .top),
                bottom: try container.decode(String.self, forKey: .bottom)
            )
        case .glassFrame:
            self = .glassFrame(
                symbol: try container.decode(String.self, forKey: .symbol),
                tint: try container.decode(Tint.self, forKey: .tint)
            )
        case .preset:
            self = .preset(name: try container.decode(String.self, forKey: .name))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cloneApp(let bundleID):
            try container.encode(Mode.cloneApp, forKey: .mode)
            try container.encode(bundleID, forKey: .bundleID)
        case .stack(let top, let bottom):
            try container.encode(Mode.stack, forKey: .mode)
            try container.encode(top, forKey: .top)
            try container.encode(bottom, forKey: .bottom)
        case .glassFrame(let symbol, let tint):
            try container.encode(Mode.glassFrame, forKey: .mode)
            try container.encode(symbol, forKey: .symbol)
            try container.encode(tint, forKey: .tint)
        case .preset(let name):
            try container.encode(Mode.preset, forKey: .mode)
            try container.encode(name, forKey: .name)
        }
    }
}
