import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

@Suite("UInt64.gigabytes")
struct UInt64GigabytesTests {

    @Test("gigabytes converts correctly")
    func gigabytesConversion() {
        #expect(UInt64.gigabytes(1) == 1_073_741_824)
        #expect(UInt64.gigabytes(8) == 8_589_934_592)
        #expect(UInt64.gigabytes(0) == 0)
    }

}
