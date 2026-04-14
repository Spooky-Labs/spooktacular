import Testing
import Foundation
@testable import SpooktacularKit

@Suite("Error descriptions")
struct ErrorTests {

    // MARK: - VirtualMachineBundleError

    @Suite("VirtualMachineBundleError")
    struct VirtualMachineBundleErrorTests {

        @Test("notFound includes the bundle name")
        func notFoundDescription() {
            let url = URL(fileURLWithPath: "/vms/test.vm")
            let error = VirtualMachineBundleError.notFound(url: url)
            let description = error.localizedDescription
            #expect(description.contains("test.vm"))
        }

        @Test("alreadyExists includes the bundle name")
        func alreadyExistsDescription() {
            let url = URL(fileURLWithPath: "/vms/dupe.vm")
            let error = VirtualMachineBundleError.alreadyExists(url: url)
            let description = error.localizedDescription
            #expect(description.contains("dupe.vm"))
        }

        @Test("invalidConfiguration mentions config.json")
        func invalidConfigDescription() {
            let url = URL(fileURLWithPath: "/vms/bad.vm")
            let error = VirtualMachineBundleError.invalidConfiguration(url: url)
            let description = error.localizedDescription
            #expect(description.contains("config.json"))
        }

        @Test("invalidMetadata mentions metadata.json")
        func invalidMetadataDescription() {
            let url = URL(fileURLWithPath: "/vms/bad.vm")
            let error = VirtualMachineBundleError.invalidMetadata(url: url)
            let description = error.localizedDescription
            #expect(description.contains("metadata.json"))
        }

    }

    // MARK: - RestoreImageError

    @Suite("RestoreImageError")
    struct RestoreImageErrorTests {

        @Test("incompatibleHost includes the provided message")
        func incompatibleHost() {
            let message = "Your macOS (26.2.0) cannot install macOS 26.4.1."
            let error = RestoreImageError.incompatibleHost(message: message)
            #expect(error.localizedDescription.contains("26.2.0"))
            #expect(error.localizedDescription.contains("26.4.1"))
        }

    }

    // MARK: - AccessibilityID

    @Suite("AccessibilityID")
    struct AccessibilityIDTests {

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
