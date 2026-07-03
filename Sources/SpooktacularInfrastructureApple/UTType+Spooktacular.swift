import UniformTypeIdentifiers

/// Type-safe Swift bindings for Spooktacular's exported UTIs.
///
/// The UTIs themselves are **registered in Info.plist**
/// (`UTExportedTypeDeclarations` + `CFBundleDocumentTypes`) — that
/// registration is what Launch Services reads at app-install /
/// app-launch time to route Finder double-clicks, wire up the
/// "Open With" menu, and resolve filename-extension → app
/// associations. Info.plist is authoritative for the system;
/// Swift cannot replace it at runtime for those purposes.
///
/// This extension exists solely for **code-side ergonomics**:
///
/// - Use `UTType.spooktacularVMBundle` in
///   `.fileImporter(allowedContentTypes:)` so the file-picker
///   only shows `.vm` bundles and folders, not unrelated
///   content.
/// - Use it as the target in SwiftUI `.dropDestination(for:)`
///   so drag-and-drop onto the sidebar only accepts bundles
///   this app authored.
/// - Use it in `UTType.conforms(to:)` checks when probing a
///   dropped URL, instead of string-comparing raw identifiers.
///
/// ## `exportedAs:` vs. string literals
///
/// Per Apple's docs
/// (<https://developer.apple.com/documentation/uniformtypeidentifiers/uttype/init(exportedas:conformingto:)>),
/// `UTType(exportedAs:conformingTo:)` declares at runtime that
/// this app is the authoritative owner of the identifier. It
/// does **not** register the type with Launch Services (that's
/// the Info.plist's job), but it does give the framework a
/// typed handle that can fail-compile instead of fail-runtime
/// if the identifier ever drifts.
///
/// Keeping the identifier string in one place (this file) and
/// re-using the `UTType` constant everywhere prevents the
/// "string typo that silently broke drag-and-drop" class of
/// regression.
///
/// See also:
/// - [Defining file and data types for your app](https://developer.apple.com/documentation/uniformtypeidentifiers/defining-file-and-data-types-for-your-app)
/// - [Launch Services Keys reference](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/LaunchServicesKeys.html)
public extension UTType {

    /// The UTI owned by this app for a portable Spooktacular
    /// VM bundle. Registered in `Resources/Info.plist` as
    /// `com.spookylabs.spooktacular.vm-bundle` with parents
    /// `com.apple.package` + `public.composite-content` and
    /// filename-extension `vm`.
    ///
    /// Conforms to `.package` so SwiftUI treats matching URLs
    /// as atomic folders (no recursion into the bundle's disk
    /// image or machine-id when shown in a file browser).
    static let spooktacularVMBundle = UTType(
        exportedAs: "com.spookylabs.spooktacular.vm-bundle",
        conformingTo: .package
    )
}
