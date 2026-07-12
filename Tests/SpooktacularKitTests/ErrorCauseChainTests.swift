import Testing
import Foundation
@testable import SpooktacularCore

@Suite("ErrorCauseChain")
struct ErrorCauseChainTests {

    /// Builds an `NSError` chain mimicking Virtualization.framework's
    /// shape: an opaque top-level error with the real cause buried
    /// in `NSUnderlyingErrorKey`.
    private func vzStyleError() -> NSError {
        let deepest = NSError(
            domain: "VZErrorDomain",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The maximum number of running virtual machines has been reached.",
            ]
        )
        let middle = NSError(
            domain: "VZErrorDomain",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "The virtual machine failed to start.",
                NSUnderlyingErrorKey: deepest,
            ]
        )
        return NSError(
            domain: "VZErrorDomain",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey: "An error occurred during installation.",
                NSUnderlyingErrorKey: middle,
            ]
        )
    }

    @Test("composed message surfaces the deepest underlying cause")
    func composedSurfacesDeepestCause() {
        let message = ErrorCauseChain.composedMessage(for: vzStyleError())
        #expect(message.contains("An error occurred during installation."))
        #expect(message.contains("maximum number of running virtual machines"))
    }

    @Test("error without an underlying chain passes through unchanged")
    func plainErrorUnchanged() {
        let plain = NSError(
            domain: "test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Disk image missing."]
        )
        #expect(ErrorCauseChain.composedMessage(for: plain) == "Disk image missing.")
    }

    @Test("identical top and underlying descriptions are not repeated")
    func duplicateDescriptionsNotRepeated() {
        let under = NSError(
            domain: "test", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Same text."]
        )
        let top = NSError(
            domain: "test", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Same text.",
                NSUnderlyingErrorKey: under,
            ]
        )
        #expect(ErrorCauseChain.composedMessage(for: top) == "Same text.")
    }

    @Test("underlyingChain walks every level in order")
    func chainWalksAllLevels() {
        let chain = ErrorCauseChain.underlyingChain(of: vzStyleError())
        #expect(chain.count == 3)
        #expect((chain[2] as NSError).code == 3)
    }
}
