import Testing
import Foundation
import AppKit
import SFSymbolsKit

/// Guards the three SF Symbol names that *cannot* be type-safe.
///
/// Every other symbol in the app goes through `String.SFSymbols.*`, so a
/// typo is a compile error. `AppShortcut.init(systemImageName:)` is the
/// one exception: it declares the parameter as `_const String`, meaning
/// Swift requires a compile-time **literal** there — the App Intents
/// metadata extractor lifts the name into the app's static shortcut
/// manifest at build time, so a `static let` (even one whose value is
/// known) is rejected with "expect a compile-time constant literal".
///
/// Those three literals in
/// `Sources/Spooktacular/Intents/VMIntents.swift` are therefore the only
/// stringly-typed symbols left in the codebase. This suite is their
/// replacement safety net: it pins each literal to the SFSymbolsKit
/// property it must equal (so a rename in the catalog fails here rather
/// than silently rendering a blank glyph in Shortcuts/Spotlight), and
/// resolves each against the running system to prove it isn't a name the
/// OS has dropped.
///
/// If a future SDK relaxes `_const` on this parameter, delete these
/// tests and use the typed properties directly.
@Suite("AppShortcut symbol literals")
struct AppShortcutSymbolTests {

    /// The literals as they appear verbatim in `VMIntents.swift`, paired
    /// with the typed property each must match.
    private static let pinned: [(literal: String, typed: String)] = [
        ("play.fill", String.SFSymbols.playFill),
        ("stop.fill", String.SFSymbols.stopFill),
        ("camera.fill", String.SFSymbols.cameraFill),
    ]

    @Test("each AppShortcut literal matches its SFSymbolsKit property")
    func literalsMatchTypedProperties() {
        for pair in Self.pinned {
            #expect(
                pair.literal == pair.typed,
                "AppShortcut literal '\(pair.literal)' no longer matches the SFSymbolsKit catalog value '\(pair.typed)' — update the literal in VMIntents.swift."
            )
        }
    }

    @Test("each AppShortcut literal resolves to a real system symbol")
    func literalsResolveOnThisSystem() {
        for pair in Self.pinned {
            let image = NSImage(
                systemSymbolName: pair.literal,
                accessibilityDescription: nil
            )
            #expect(
                image != nil,
                "'\(pair.literal)' does not resolve as an SF Symbol on this system — it would render as a blank glyph in Shortcuts."
            )
        }
    }
}
