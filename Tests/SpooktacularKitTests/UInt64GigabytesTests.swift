import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpooktacularInfrastructureApple
@testable import SpooktacularApplication
@testable import SpooktacularCore

@Suite("UInt64.gigabytes", .tags(.infrastructure))
struct UInt64GigabytesTests {

    @Test(
        "Converts gigabytes to bytes correctly",
        arguments: [
            (UInt64(0), UInt64(0)),
            (UInt64(1), UInt64(1_073_741_824)),
            (UInt64(8), UInt64(8_589_934_592)),
        ]
    )
    func gigabytesConversion(input: UInt64, expected: UInt64) {
        #expect(UInt64.gigabytes(input) == expected)
    }
}
