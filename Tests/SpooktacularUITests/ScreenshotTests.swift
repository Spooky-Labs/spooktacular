import XCTest

/// Automated App Store screenshot capture for Spooktacular.
///
/// These tests use XCUITest to launch the app, navigate to key
/// screens, and capture screenshots for App Store and TestFlight
/// submission. Each screenshot is saved as a test attachment.
///
/// ## Running
///
/// ### From Xcode
///
/// 1. Open `Package.swift` in Xcode
/// 2. Add a UI Testing Bundle target (File → New → Target)
/// 3. Move this file into the new target
/// 4. Run tests: Product → Test (Cmd+U)
///
/// ### From the command line
///
/// ```bash
/// xcodebuild test \
///   -scheme Spooktacular \
///   -destination 'platform=macOS' \
///   -only-testing:SpooktacularUITests
/// ```
///
/// ## App Store Screenshot Sizes (macOS)
///
/// | Display | Size |
/// |---------|------|
/// | 13" Retina | 2560×1600 |
/// | 16" Retina | 2880×1800 |
///
/// Post-process with `scripts/process-screenshots.sh`.
///
/// ## Wait strategy
///
/// Every navigation step uses event-based waits
/// (`waitForExistence(timeout:)`) rather than
/// `Thread.sleep(forTimeInterval:)`. Fixed sleeps are a common
/// source of flakes in CI: the one animation-settle duration
/// that works on a fresh local macOS host is not the one that
/// works on a busy `macos-26` runner, so we let the XCUITest
/// framework poll the view hierarchy and proceed as soon as
/// the target element is present.
@MainActor
final class ScreenshotTests: XCTestCase {

    // swiftlint:disable:next implicitly_unwrapped_optional
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()

        // Wait for the main window.
        let window = app.windows.firstMatch
        XCTAssertTrue(
            window.waitForExistence(timeout: 10),
            "App window should appear"
        )
    }

    override func tearDown() async throws {
        app.terminate()
        app = nil
    }

    // MARK: - Helper

    /// Captures a named screenshot and attaches it to the test.
    ///
    /// Uses `waitForExistence` on the window to replace the
    /// previous `Thread.sleep(forTimeInterval: 0.5)` — the
    /// fixed sleep masked races on slow hosts and wasted time
    /// on fast ones.
    private func captureScreenshot(named name: String) {
        // Ensure the window is hit-testable before grabbing
        // pixels. `waitForExistence` returns immediately on hit
        // and polls at ~100ms intervals otherwise, so the test
        // is both faster on healthy hosts and more reliable on
        // busy ones.
        let window = app.windows.firstMatch
        XCTAssertTrue(
            window.waitForExistence(timeout: 5),
            "window must exist before screenshotting"
        )

        let screenshot = window.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Captures the entire screen (including menu bar and Dock).
    private func captureFullScreen(named name: String) {
        // Same reasoning as `captureScreenshot(named:)` —
        // confirm the app window exists first so the screen
        // shot is framed around a hosted window, not a
        // half-drawn launch state.
        let window = app.windows.firstMatch
        XCTAssertTrue(
            window.waitForExistence(timeout: 5),
            "window must exist before full-screen capture"
        )

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Screenshots

    /// 1. Empty state — the welcome screen when no VMs exist.
    ///
    /// Shows the ContentUnavailableView with the "Create VM" button.
    /// This is the first thing a new user sees.
    func test01_EmptyState() {
        captureScreenshot(named: "01_empty_state")
    }

    /// 2. Create VM sheet — the two-column form.
    ///
    /// Opens the sheet and fills in a sample name so the form
    /// looks realistic in the screenshot.
    func test02_CreateVMSheet() {
        // Click the EmptyState "Create VM" button directly rather
        // than relying on the `⌘N` keyboard shortcut — on headless
        // CI macOS runners `typeKey` occasionally doesn't reach
        // the app's responder chain (observed: run 24620349705 —
        // sheet never appeared within 5s). Clicking the button by
        // accessibility identifier is deterministic.
        // `.firstMatch` is important: the `createVMButton`
        // accessibility identifier is applied both to the
        // EmptyStateView button (ContentView.swift:112) and to
        // the sidebar "+ Add VM" button (SidebarView.swift:59).
        // Without firstMatch, XCUIElementQuery raises "Multiple
        // matching elements found" (observed on run 24620603778).
        let createButton = app.buttons["createVMButton"].firstMatch
        if createButton.waitForExistence(timeout: 5) {
            createButton.click()
        } else {
            // Fallback for subsequent runs where the empty state
            // is no longer visible (a VM exists). Use ⌘N then.
            app.typeKey("n", modifierFlags: .command)
        }

        // Wait for the sheet to appear by looking for the name field.
        let nameField = app.textFields["vmNameField"]
        guard nameField.waitForExistence(timeout: 10) else {
            XCTFail("Create VM sheet did not appear")
            return
        }

        // Type a realistic name.
        nameField.click()
        nameField.typeText("ci-runner-01")

        captureScreenshot(named: "02_create_vm_sheet")

        // Dismiss the sheet.
        app.typeKey(.escape, modifierFlags: [])
    }

    /// 3. VM list — sidebar with VMs and image library.
    ///
    /// Best captured when mock VMs exist (run after `spook create`
    /// has been used to create test VMs).
    func test03_VMList() {
        captureScreenshot(named: "03_vm_list")
    }

    /// 4. VM launch screen — the centered Start button view.
    ///
    /// Clicks the first VM in the sidebar to show the launch screen
    /// with hardware summary and the Start button.
    func test04_LaunchScreen() {
        // Try to select the first VM in the sidebar.
        let sidebar = app.outlines.firstMatch
        if sidebar.exists {
            let firstCell = sidebar.cells.firstMatch
            if firstCell.waitForExistence(timeout: 3) {
                firstCell.click()
                // Wait for the launch-screen Start button to
                // exist — replaces a `Thread.sleep(0.5)` that
                // was racing animation on busy hosts.
                let startButton = app.buttons["vmStartButton"]
                _ = startButton.waitForExistence(timeout: 5)
            }
        }

        captureScreenshot(named: "04_launch_screen")
    }

    /// 5. Inspector panel — configuration details alongside the
    /// launch screen or VM display.
    func test05_Inspector() {
        // Select first VM.
        let sidebar = app.outlines.firstMatch
        if sidebar.exists {
            let firstCell = sidebar.cells.firstMatch
            if firstCell.waitForExistence(timeout: 3) {
                firstCell.click()
            }
        }

        // Toggle inspector.
        let inspectorButton = app.buttons["inspectorToggle"]
        if inspectorButton.waitForExistence(timeout: 3) {
            inspectorButton.click()
            // Wait for a known inspector element to appear,
            // rather than sleeping. The inspector exposes the
            // `inspectorPane` accessibility identifier.
            let pane = app.otherElements["inspectorPane"]
            _ = pane.waitForExistence(timeout: 5)
        }

        captureScreenshot(named: "05_inspector")
    }

    /// 6. Menu bar — the dropdown with VM status and quick actions.
    ///
    /// Note: Menu bar screenshots may require manual capture since
    /// activating the menu bar extra programmatically is unreliable.
    func test06_MenuBar() {
        // Capture the full screen which includes the menu bar.
        captureFullScreen(named: "06_full_app")
    }
}
