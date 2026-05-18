import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpooktacularInfrastructureApple
@testable import SpooktacularApplication
@testable import SpooktacularCore

@Suite("SSHExecutor", .tags(.networking))
struct SSHExecutorTests {

    // MARK: - SSH Options

    @Suite("SSH options")
    struct SSHOptions {

        @Test("default options enforce trust-on-first-use, not blind acceptance", arguments: [
            "StrictHostKeyChecking=accept-new",
            "LogLevel=ERROR",
            "ConnectTimeout=",
        ])
        func defaultOptions(expected: String) {
            let joined = SSHExecutor.sshOptions.joined(separator: " ")
            #expect(joined.contains(expected))
        }

        @Test("default options do NOT include /dev/null known-hosts (blind trust)")
        func defaultDoesNotBypassHostKey() {
            let joined = SSHExecutor.sshOptions.joined(separator: " ")
            #expect(!joined.contains("UserKnownHostsFile=/dev/null"),
                    "Default must not use /dev/null — that's the MITM-friendly mode")
            #expect(!joined.contains("StrictHostKeyChecking=no"),
                    "Default must not disable strict host-key checking")
        }

        @Test(".acceptAny mode produces the legacy ephemeral-VM options")
        func acceptAnyMode() {
            let opts = SSHExecutor.sshOptions(trust: .acceptAny).joined(separator: " ")
            #expect(opts.contains("StrictHostKeyChecking=no"))
            #expect(opts.contains("UserKnownHostsFile=/dev/null"))
        }

        @Test(".strict mode enforces yes + known_hosts")
        func strictMode() {
            let opts = SSHExecutor.sshOptions(
                trust: .strict(knownHostsPath: "/tmp/kh")
            ).joined(separator: " ")
            #expect(opts.contains("StrictHostKeyChecking=yes"))
            #expect(opts.contains("UserKnownHostsFile=/tmp/kh"))
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
