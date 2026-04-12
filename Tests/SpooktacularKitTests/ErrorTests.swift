import Testing
import Foundation
@testable import SpooktacularKit

@Suite("Error descriptions")
struct ErrorTests {

    // MARK: - VMBundleError

    @Suite("VMBundleError")
    struct VMBundleErrorTests {

        @Test("notFound includes the bundle name")
        func notFoundDescription() {
            let url = URL(fileURLWithPath: "/vms/test.vm")
            let error = VMBundleError.notFound(url: url)
            let description = error.localizedDescription
            #expect(description.contains("test.vm"))
        }

        @Test("alreadyExists includes the bundle name")
        func alreadyExistsDescription() {
            let url = URL(fileURLWithPath: "/vms/dupe.vm")
            let error = VMBundleError.alreadyExists(url: url)
            let description = error.localizedDescription
            #expect(description.contains("dupe.vm"))
        }

        @Test("invalidConfiguration mentions config.json")
        func invalidConfigDescription() {
            let url = URL(fileURLWithPath: "/vms/bad.vm")
            let error = VMBundleError.invalidConfiguration(url: url)
            let description = error.localizedDescription
            #expect(description.contains("config.json"))
        }

        @Test("invalidMetadata mentions metadata.json")
        func invalidMetadataDescription() {
            let url = URL(fileURLWithPath: "/vms/bad.vm")
            let error = VMBundleError.invalidMetadata(url: url)
            let description = error.localizedDescription
            #expect(description.contains("metadata.json"))
        }

        @Test("Every case has a non-empty description")
        func allCasesDescribed() {
            let url = URL(fileURLWithPath: "/test.vm")
            let cases: [VMBundleError] = [
                .notFound(url: url),
                .alreadyExists(url: url),
                .invalidConfiguration(url: url),
                .invalidMetadata(url: url),
            ]
            for error in cases {
                #expect(!error.localizedDescription.isEmpty)
            }
        }
    }

    // MARK: - RestoreImageError

    @Suite("RestoreImageError")
    struct RestoreImageErrorTests {

        @Test("unsupportedHost has a description")
        func unsupportedHost() {
            let error = RestoreImageError.unsupportedHost
            #expect(!error.localizedDescription.isEmpty)
        }

        @Test("unsupportedHardwareModel has a description")
        func unsupportedHardwareModel() {
            let error = RestoreImageError.unsupportedHardwareModel
            #expect(!error.localizedDescription.isEmpty)
        }

        @Test("incompatibleHost includes the provided message")
        func incompatibleHost() {
            let message = "Your macOS (26.2.0) cannot install macOS 26.4.1."
            let error = RestoreImageError.incompatibleHost(message: message)
            #expect(error.localizedDescription.contains("26.2.0"))
            #expect(error.localizedDescription.contains("26.4.1"))
        }

        @Test("Every case has a non-empty description")
        func allCasesDescribed() {
            let cases: [RestoreImageError] = [
                .unsupportedHost,
                .unsupportedHardwareModel,
                .incompatibleHost(message: "test"),
            ]
            for error in cases {
                #expect(!error.localizedDescription.isEmpty)
            }
        }
    }

    // MARK: - AccessibilityID

    @Suite("AccessibilityID")
    struct AccessibilityIDTests {

        @Test("Static identifiers are non-empty strings")
        func staticIDs() {
            let ids = [
                AccessibilityID.vmList,
                AccessibilityID.createVMButton,
                AccessibilityID.createSheet,
                AccessibilityID.vmNameField,
                AccessibilityID.cpuStepper,
                AccessibilityID.memorySlider,
                AccessibilityID.diskSlider,
                AccessibilityID.displayPicker,
                AccessibilityID.networkPicker,
                AccessibilityID.createConfirmButton,
                AccessibilityID.cancelButton,
                AccessibilityID.startButton,
                AccessibilityID.stopButton,
                AccessibilityID.inspectorToggle,
                AccessibilityID.progressIndicator,
                AccessibilityID.statusMessage,
            ]
            for id in ids {
                #expect(!id.isEmpty, "Accessibility identifier must not be empty")
            }
        }

        @Test("Dynamic identifiers include the name parameter")
        func dynamicIDs() {
            #expect(AccessibilityID.vmRow("test").contains("test"))
            #expect(AccessibilityID.vmDisplay("dev").contains("dev"))
        }

        @Test("Dynamic identifiers are unique per name")
        func uniqueDynamicIDs() {
            #expect(AccessibilityID.vmRow("a") != AccessibilityID.vmRow("b"))
            #expect(AccessibilityID.vmDisplay("a") != AccessibilityID.vmDisplay("b"))
        }
    }
}
