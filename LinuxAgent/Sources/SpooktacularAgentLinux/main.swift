import Foundation
import Glibc

/// Entry point.
///
/// Usage:
///   spooktacular-agent                 → start the agent (systemd
///                                        drops env + logging here)
///   spooktacular-agent --install-unit  → write a systemd unit to
///                                        /etc/systemd/system/ and
///                                        enable + start it
///
/// Ports mirror the macOS agent:
///   9470 — read-only (health, stats, ports, event stream)
///   9471 — runner   (reserved for future Linux parity endpoints)
///   9472 — break-glass (reserved; Linux agent has no exec today)
///
/// Only 9470 is actually bound in this minimal Linux port.
/// Binding 9471 / 9472 with no routes would give the host a
/// connection that immediately 404s — worse than the host
/// observing ECONNREFUSED and falling through to
/// "Linux-agent has no runner channel". We wire them when we
/// add the matching endpoints, not sooner.

let readonlyPort: UInt32 = 9470
let systemdUnitPath = "/etc/systemd/system/spooktacular-agent.service"
let installedBinary = "/usr/local/bin/spooktacular-agent"

/// Plain stdout logger. systemd captures stdout as journald by
/// default on the `simple` service type we generate, so
/// `journalctl -u spooktacular-agent` is the single pane the
/// operator sees. No os.Logger equivalent on Linux — print is
/// the right level of ceremony here.
func log(_ message: @autoclosure () -> String) {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    FileHandle.standardOutput.write(Data("[\(iso.string(from: Date()))] \(message())\n".utf8))
}

let arguments = CommandLine.arguments

if arguments.contains("--install-unit") {
    installSystemdUnit()
    exit(0)
}

log("spooktacular-agent (linux) starting — dialing host vsock:\(HostDialer.eventPort)")
HostDialer(stats: StatsCoordinator()).run()

// MARK: - systemd install

/// Writes a minimal systemd service unit + enables/starts it.
/// Run as root; on failure, prints the underlying error so the
/// installer-user can see what went wrong (permissions issue,
/// systemd not present, etc.).
func installSystemdUnit() {
    let unit = """
    [Unit]
    Description=Spooktacular guest agent
    After=network.target

    [Service]
    Type=simple
    ExecStart=\(installedBinary)
    Restart=on-failure
    RestartSec=2s
    # systemd's `Type=simple` expects the service to stay in the
    # foreground and log to stdout/stderr — matches the agent's
    # `VsockServer.run() -> Never` loop.
    StandardOutput=journal
    StandardError=journal

    [Install]
    WantedBy=multi-user.target
    """

    do {
        try unit.write(toFile: systemdUnitPath, atomically: true, encoding: .utf8)
        log("wrote \(systemdUnitPath)")
    } catch {
        log("failed to write \(systemdUnitPath): \(error.localizedDescription)")
        exit(1)
    }

    // Daemon reload is the canonical systemd dance after editing
    // a unit file. Enable + start in one go so the operator
    // doesn't have to remember the verbs.
    runCommand(["systemctl", "daemon-reload"])
    runCommand(["systemctl", "enable", "--now", "spooktacular-agent.service"])
    log("agent installed and started. Verify with:")
    log("  systemctl status spooktacular-agent")
    log("  journalctl -u spooktacular-agent -f")
}

/// Runs a subprocess with the given argv. Logs the outcome; a
/// non-zero exit aborts the installer so systemctl failures
/// don't get silently swallowed.
func runCommand(_ argv: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = argv
    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            log("\(argv.joined(separator: " ")) exited with \(process.terminationStatus)")
            exit(Int32(process.terminationStatus))
        }
    } catch {
        log("failed to spawn \(argv.joined(separator: " ")): \(error.localizedDescription)")
        exit(1)
    }
}
