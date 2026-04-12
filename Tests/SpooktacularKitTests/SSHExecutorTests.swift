import Testing
import Foundation
@testable import SpooktacularKit

@Suite("SSHExecutor")
struct SSHExecutorTests {

    // MARK: - SSH Options

    @Test("SSH options disable strict host key checking")
    func disablesHostKeyChecking() {
        let opts = SSHExecutor.sshOptions
        let joined = opts.joined(separator: " ")
        #expect(joined.contains("StrictHostKeyChecking=no"))
    }

    @Test("SSH options use /dev/null for known hosts")
    func devNullKnownHosts() {
        let opts = SSHExecutor.sshOptions
        let joined = opts.joined(separator: " ")
        #expect(joined.contains("UserKnownHostsFile=/dev/null"))
    }

    @Test("SSH options suppress log output")
    func suppressesLogs() {
        let opts = SSHExecutor.sshOptions
        let joined = opts.joined(separator: " ")
        #expect(joined.contains("LogLevel=ERROR"))
    }

    @Test("SSH options set a connect timeout")
    func connectTimeout() {
        let opts = SSHExecutor.sshOptions
        let joined = opts.joined(separator: " ")
        #expect(joined.contains("ConnectTimeout="))
    }

    // MARK: - SSHError

    @Test("Timeout error includes IP and duration")
    func timeoutError() {
        let error = SSHError.timeout(ip: "192.168.64.2", seconds: 120)
        let desc = error.localizedDescription
        #expect(desc.contains("192.168.64.2"))
        #expect(desc.contains("120"))
    }

    @Test("SCP failed error includes exit code")
    func scpFailedError() {
        let error = SSHError.scpFailed(exitCode: 1)
        let desc = error.localizedDescription
        #expect(desc.contains("scp"))
        #expect(desc.contains("1"))
    }

    @Test("Execution failed error includes exit code")
    func executionFailedError() {
        let error = SSHError.executionFailed(exitCode: 127)
        let desc = error.localizedDescription
        #expect(desc.contains("127"))
    }

    @Test("SSHError is equatable")
    func equatable() {
        #expect(SSHError.timeout(ip: "1.2.3.4", seconds: 60) == SSHError.timeout(ip: "1.2.3.4", seconds: 60))
        #expect(SSHError.timeout(ip: "1.2.3.4", seconds: 60) != SSHError.timeout(ip: "5.6.7.8", seconds: 60))
        #expect(SSHError.scpFailed(exitCode: 1) == SSHError.scpFailed(exitCode: 1))
        #expect(SSHError.scpFailed(exitCode: 1) != SSHError.scpFailed(exitCode: 2))
        #expect(SSHError.executionFailed(exitCode: 0) == SSHError.executionFailed(exitCode: 0))
    }

    @Test("All SSHError cases have non-empty descriptions")
    func allCasesDescribed() {
        let cases: [SSHError] = [
            .timeout(ip: "10.0.0.1", seconds: 30),
            .scpFailed(exitCode: 1),
            .executionFailed(exitCode: 1),
        ]
        for error in cases {
            #expect(!error.localizedDescription.isEmpty)
        }
    }
}
