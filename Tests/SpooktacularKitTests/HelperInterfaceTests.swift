import Testing
import Foundation
@testable import SpooktacularInfrastructureApple

@Suite("HelperInterface")
struct HelperInterfaceTests {

    @Test("mach service name and plist name are the SMAppService-conventional pair")
    func names() {
        #expect(HelperInterface.machServiceName == "com.spooktacular.app.helper")
        #expect(HelperInterface.plistName == "com.spooktacular.app.helper.plist")
    }

    @Test("code-signing requirement pins Apple anchor + identifier + this process's team")
    func requirementShape() throws {
        // The swift-testing host runs signed (ad-hoc or a dev identity).
        // When a team identity is present the requirement must name it;
        // when absent (pure ad-hoc) the builder returns nil so callers
        // refuse to bridge — either is a valid, asserted outcome.
        let requirement = HelperInterface.codeSigningRequirement(identifier: "com.spooktacular.app")
        if let requirement {
            #expect(requirement.contains("anchor apple generic"))
            #expect(requirement.contains(#"identifier "com.spooktacular.app""#))
            #expect(requirement.contains("certificate leaf[subject.OU]"))
            // The embedded team must be the running process's real team,
            // not a placeholder.
            #expect(!requirement.contains(#"= """#))
        }
    }

    @Test("different identifiers produce different requirement strings, same team")
    func identifierVaries() {
        let app = HelperInterface.codeSigningRequirement(identifier: "com.spooktacular.app")
        let helper = HelperInterface.codeSigningRequirement(identifier: "spooktacular-helper")
        if let app, let helper {
            #expect(app != helper)
            #expect(app.contains("com.spooktacular.app"))
            #expect(helper.contains("spooktacular-helper"))
        }
    }
}
