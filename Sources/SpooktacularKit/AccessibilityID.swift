/// Shared accessibility identifiers for UI testing.
///
/// These identifiers are used by both the SwiftUI views
/// (via `.accessibilityIdentifier()`) and the UI test target
/// (via `app.buttons[AccessibilityID.startButton]`).
///
/// Centralizing identifiers in one place prevents typos
/// and ensures deterministic test element lookup.
///
/// ## Usage in Views
///
/// ```swift
/// Button("Start") { ... }
///     .accessibilityIdentifier(AccessibilityID.startButton)
/// ```
///
/// ## Usage in UI Tests
///
/// ```swift
/// let startButton = app.buttons[AccessibilityID.startButton]
/// XCTAssertTrue(startButton.exists)
/// startButton.click()
/// ```
public enum AccessibilityID {

    // MARK: - Sidebar

    /// The VM list in the sidebar.
    public static let vmList = "vmList"

    /// The "Create VM" toolbar button.
    public static let createVMButton = "createVMButton"

    /// The sidebar search field.
    public static let searchField = "searchField"

    /// A row in the VM list. Parameterized by VM name.
    public static func vmRow(_ name: String) -> String {
        "vmRow-\(name)"
    }

    // MARK: - Detail View

    /// The "Start" button in the detail toolbar.
    public static let startButton = "startButton"

    /// The "Stop" button in the detail toolbar.
    public static let stopButton = "stopButton"

    /// The "Inspector" toggle button.
    public static let inspectorToggle = "inspectorToggle"

    /// The VM display view. Parameterized by VM name.
    public static func vmDisplay(_ name: String) -> String {
        "vmDisplay-\(name)"
    }

    // MARK: - Create VM Sheet

    /// The create VM sheet container.
    public static let createSheet = "createVMSheet"

    /// The VM name text field.
    public static let vmNameField = "vmNameField"

    /// The CPU cores stepper.
    public static let cpuStepper = "cpuStepper"

    /// The memory slider.
    public static let memorySlider = "memorySlider"

    /// The disk size slider.
    public static let diskSlider = "diskSlider"

    /// The display count picker.
    public static let displayPicker = "displayPicker"

    /// The network mode picker.
    public static let networkPicker = "networkPicker"

    /// The "Create" confirmation button.
    public static let createConfirmButton = "createConfirmButton"

    /// The "Cancel" button.
    public static let cancelButton = "cancelButton"

    // MARK: - Progress

    /// The download/install progress indicator.
    public static let progressIndicator = "progressIndicator"

    /// The status message during creation.
    public static let statusMessage = "statusMessage"
}
