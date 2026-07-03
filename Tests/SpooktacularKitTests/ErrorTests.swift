import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpooktacularInfrastructureApple
@testable import SpooktacularApplication
@testable import SpooktacularCore

@Suite("Error descriptions", .tags(.infrastructure))
struct ErrorTests {

    // MARK: - VirtualMachineBundleError

    @Suite("VirtualMachineBundleError", .tags(.infrastructure))
    struct VirtualMachineBundleErrorTests {

        @Test(
            "Error descriptions include relevant identifiers",
            arguments: [
                (
                    VirtualMachineBundleError.notFound(url: URL(fileURLWithPath: "/vms/test.vm")),
                    "test.vm"
                ),
                (
                    VirtualMachineBundleError.alreadyExists(url: URL(fileURLWithPath: "/vms/dupe.vm")),
                    "dupe.vm"
                ),
                (
                    VirtualMachineBundleError.invalidConfiguration(url: URL(fileURLWithPath: "/vms/bad.vm")),
                    "config.json"
                ),
                (
                    VirtualMachineBundleError.invalidMetadata(url: URL(fileURLWithPath: "/vms/bad.vm")),
                    "metadata.json"
                ),
            ]
        )
        func errorDescription(error: VirtualMachineBundleError, expectedSubstring: String) {
            #expect(error.localizedDescription.contains(expectedSubstring))
        }
    }

    // MARK: - RestoreImageError

    @Suite("RestoreImageError", .tags(.infrastructure))
    struct RestoreImageErrorTests {

        @Test("incompatibleHost includes the provided version strings")
        func incompatibleHost() {
            let message = "Your macOS (26.2.0) cannot install macOS 26.4.1."
            let error = RestoreImageError.incompatibleHost(message: message)
            #expect(error.localizedDescription.contains("26.2.0"))
            #expect(error.localizedDescription.contains("26.4.1"))
        }
    }

    // MARK: - AccessibilityID

    @Suite("AccessibilityID", .tags(.infrastructure))
    struct AccessibilityIDTests {

        @Test("vmRow includes the name and differs per name")
        func vmRowDynamic() {
            #expect(AccessibilityID.vmRow("test").contains("test"))
            #expect(AccessibilityID.vmRow("a") != AccessibilityID.vmRow("b"))
        }

        @Test("vmDisplay includes the name and differs per name")
        func vmDisplayDynamic() {
            #expect(AccessibilityID.vmDisplay("dev").contains("dev"))
            #expect(AccessibilityID.vmDisplay("a") != AccessibilityID.vmDisplay("b"))
        }
    }
}
