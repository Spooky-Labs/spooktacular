import XCTest

/// Automated App Store screenshot capture for Spooktacular.
///
/// These tests launch the app, navigate to key screens, and
/// capture screenshots using `XCUIScreenshot`. The screenshots
/// are saved as test attachments and can be exported for
/// App Store / TestFlight submission.
///
/// ## Running
///
/// From Xcode:
///   Product → Test (Cmd+U) with the SpooktacularUITests scheme
///
/// From the command line:
///   xcodebuild test -scheme SpooktacularUITests -destination 'platform=macOS'
///
/// ## App Store macOS Screenshot Sizes
///
/// - 1280×800  (13" non-Retina)
/// - 1440×900  (13" non-Retina alt)
/// - 2560×1600 (13" Retina)
/// - 2880×1800 (15"/16" Retina)
///
/// Screenshots are captured at the current screen resolution.
/// Resize with `sips` or a Fastlane post-processing step.
final class ScreenshotTests: XCTestCase {

    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()

        // Wait for the main window to appear.
        let window = app.windows.firstMatch
        XCTAssertTrue(
            window.waitForExistence(timeout: 10),
            "App window should appear within 10 seconds"
        )
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Screenshots

    /// 1. Empty state — the landing page when no VMs exist.
    func testScreenshot01_EmptyState() throws {
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "01_empty_state"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 2. Create VM sheet — the two-column form with all options.
    func testScreenshot02_CreateVMSheet() throws {
        // Click the + button in the toolbar to open the sheet.
        let createButton = app.buttons["createVMButton"]
        if createButton.exists {
            createButton.click()
        } else {
            // Fallback: use keyboard shortcut.
            app.typeKey("n", modifierFlags: .command)
        }

        // Wait for the sheet to appear.
        let nameField = app.textFields["vmNameField"]
        let sheetAppeared = nameField.waitForExistence(timeout: 5)
        XCTAssertTrue(sheetAppeared, "Create VM sheet should appear")

        // Type a sample name so the form looks populated.
        if sheetAppeared {
            nameField.click()
            nameField.typeText("ci-runner-01")
        }

        sleep(1) // Let animations settle.

        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "02_create_vm_sheet"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 3. VM list with VMs in the sidebar.
    func testScreenshot03_VMList() throws {
        // This screenshot is most useful when VMs exist.
        // The test captures whatever state the app is in.
        sleep(1)

        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "03_vm_list"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 4. VM detail / launch screen with hardware summary.
    func testScreenshot04_VMDetail() throws {
        // Click the first VM in the sidebar (if any exist).
        let sidebar = app.outlines.firstMatch
        if sidebar.exists {
            let firstRow = sidebar.cells.firstMatch
            if firstRow.waitForExistence(timeout: 3) {
                firstRow.click()
                sleep(1)
            }
        }

        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "04_vm_detail"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 5. Inspector panel open alongside the detail view.
    func testScreenshot05_Inspector() throws {
        // Open inspector with the toolbar button.
        let inspectorButton = app.buttons["inspectorToggle"]
        if inspectorButton.waitForExistence(timeout: 3) {
            inspectorButton.click()
            sleep(1)
        }

        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "05_inspector"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 6. Full app screenshot — for the primary App Store listing.
    func testScreenshot06_FullApp() throws {
        // Capture the entire screen (shows menu bar + Dock context).
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "06_full_screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
