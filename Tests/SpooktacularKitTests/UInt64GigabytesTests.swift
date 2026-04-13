import Testing
import Foundation
@testable import SpooktacularKit

@Suite("UInt64.gigabytes")
struct UInt64GigabytesTests {

    @Test("gigabytes converts correctly")
    func gigabytesConversion() {
        #expect(UInt64.gigabytes(1) == 1_073_741_824)
        #expect(UInt64.gigabytes(8) == 8_589_934_592)
        #expect(UInt64.gigabytes(0) == 0)
    }

    @Test("gigabytes matches manual multiplication")
    func gigabytesMatchesManual() {
        let manual: UInt64 = 16 * 1024 * 1024 * 1024
        #expect(UInt64.gigabytes(16) == manual)
    }

    @Test("gigabytes works with typical VM memory sizes")
    func typicalVMSizes() {
        // 4 GB minimum memory
        #expect(UInt64.gigabytes(4) == 4_294_967_296)
        // 64 GB typical large VM
        #expect(UInt64.gigabytes(64) == 68_719_476_736)
    }
}
