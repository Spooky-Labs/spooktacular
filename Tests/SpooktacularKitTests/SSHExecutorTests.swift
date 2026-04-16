import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

@Suite("SSHExecutor", .tags(.networking))
struct SSHExecutorTests {

    // MARK: - SSH Options

    @Suite("SSH options")
    struct SSHOptions {

        @Test("options contain all required security-bypass flags", arguments: [
            "StrictHostKeyChecking=no",
            "UserKnownHostsFile=/dev/null",
            "LogLevel=ERROR",
            "ConnectTimeout=",
        ])
        func containsExpectedOption(expected: String) {
            let joined = SSHExecutor.sshOptions.joined(separator: " ")
            #expect(joined.contains(expected))
        }
    }

    // MARK: - SSHError

    @Suite("SSHError")
    struct SSHErrorTests {

        @Test("timeout error description includes IP and duration",
              .timeLimit(.minutes(1)))
        func timeoutError() {
            let error = SSHError.timeout(ip: "192.168.64.2", seconds: 120)
            let desc = error.localizedDescription
            #expect(desc.contains("192.168.64.2"))
            #expect(desc.contains("120"))
        }

        @Test("scpFailed error description includes scp and exit code",
              .timeLimit(.minutes(1)))
        func scpFailedError() {
            let error = SSHError.scpFailed(exitCode: 1)
            let desc = error.localizedDescription
            #expect(desc.contains("scp"))
            #expect(desc.contains("1"))
        }

        @Test("executionFailed error description includes exit code",
              .timeLimit(.minutes(1)))
        func executionFailedError() {
            let error = SSHError.executionFailed(exitCode: 127)
            let desc = error.localizedDescription
            #expect(desc.contains("127"))
        }

        @Test("equatable: same values are equal", arguments: [
            (SSHError.timeout(ip: "1.2.3.4", seconds: 60),
             SSHError.timeout(ip: "1.2.3.4", seconds: 60), true),
            (SSHError.timeout(ip: "1.2.3.4", seconds: 60),
             SSHError.timeout(ip: "5.6.7.8", seconds: 60), false),
            (SSHError.scpFailed(exitCode: 1),
             SSHError.scpFailed(exitCode: 1), true),
            (SSHError.scpFailed(exitCode: 1),
             SSHError.scpFailed(exitCode: 2), false),
            (SSHError.executionFailed(exitCode: 0),
             SSHError.executionFailed(exitCode: 0), true),
        ] as [(SSHError, SSHError, Bool)])
        func equatable(lhs: SSHError, rhs: SSHError, shouldBeEqual: Bool) {
            #expect((lhs == rhs) == shouldBeEqual)
        }
    }
}
