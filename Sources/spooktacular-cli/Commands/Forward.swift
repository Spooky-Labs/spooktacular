import ArgumentParser
import Foundation
import SpooktacularKit
@preconcurrency import Virtualization

extension Spooktacular {

    /// Forwards host TCP ports to guest localhost ports via
    /// vsock, the same technique GhostVM uses to expose an
    /// in-guest web server at `http://localhost:<port>` on the
    /// host without touching NAT or bridged networking.
    ///
    /// ## Apple APIs behind this command
    ///
    /// - [`NWListener`](https://developer.apple.com/documentation/network/nwlistener)
    ///   on `127.0.0.1:<host-port>` — accepts incoming TCP on
    ///   the host.
    /// - [`VZVirtioSocketDevice.connect(toPort:)`](https://developer.apple.com/documentation/virtualization/vzvirtiosocketdevice/connect(toport:))
    ///   opens the vsock leg to the guest agent's tunnel
    ///   endpoint (port 9473).
    /// - The guest agent then `connect(2)`s to
    ///   `127.0.0.1:<guest-port>` inside the VM and splices
    ///   bytes bidirectionally.
    ///
    /// ## Examples
    ///
    /// ```sh
    /// # Expose guest's HTTP dev server at host's :3000
    /// spooktacular forward my-vm 3000:3000
    ///
    /// # Multiple mappings in one invocation
    /// spooktacular forward my-vm 8080:80 5432:5432
    ///
    /// # Different host port from guest port
    /// spooktacular forward my-vm 18080:80
    /// ```
    struct Forward: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "forward",
            abstract: "Forward host TCP ports to guest localhost ports over vsock.",
            discussion: """
                Starts a host-side listener on 127.0.0.1:<host-port> \
                for each <host>:<guest> pair and tunnels bytes to \
                127.0.0.1:<guest-port> inside the VM via the \
                agent's tunnel channel on vsock port 9473.

                The forwarder runs in the foreground; Ctrl-C \
                cleanly tears down every listener. The VM must be \
                running with the updated agent — older agents \
                without the tunnel port will return 403 on the \
                CONNECT handshake.

                Privileged ports (1-1023) inside the guest are \
                rejected by default; set \
                SPOOKTACULAR_TUNNEL_ALLOW_PRIVILEGED=1 in the \
                guest's env to override (see \
                TunnelHandler.swift for rationale).

                EXAMPLES:
                  spooktacular forward my-vm 3000:3000
                  spooktacular forward my-vm 8080:80 5432:5432
                """
        )

        @Argument(help: "Name of the running VM.")
        var name: String

        @Argument(
            help: "Port mappings in the form <host>:<guest>. Multiple allowed."
        )
        var mappings: [String]

        @MainActor
        func run() async throws {
            guard !mappings.isEmpty else {
                print(Style.error("✗ At least one <host>:<guest> mapping is required."))
                throw ExitCode.failure
            }

            let parsed = try mappings.map { try parseMapping($0) }
            let bundleURL = try requireBundle(for: name)

            guard PIDFile.isRunning(bundleURL: bundleURL) else {
                print(Style.error("✗ VM '\(name)' is not running."))
                print(Style.dim("  Start it with: spooktacular start \(name)"))
                throw ExitCode.failure
            }

            // Build a VirtualMachine handle solely to reach its
            // VZVirtioSocketDevice. This doesn't START a new VM
            // — VirtualMachine(bundle:) constructs the wrapper
            // against the existing running instance by
            // re-loading its platform config. Matches what
            // Remote.requireAgent does for its vsock RPCs.
            let bundle = try VirtualMachineBundle.load(from: bundleURL)
            let vm = try VirtualMachine(bundle: bundle)
            guard let socketDevice = vm.vzVM?.socketDevices.first as? VZVirtioSocketDevice else {
                print(Style.error("✗ VM has no vsock device — cannot tunnel."))
                throw ExitCode.failure
            }

            var forwarders: [PortForwarder] = []
            for (hostPort, guestPort) in parsed {
                let fwd = PortForwarder(
                    hostPort: hostPort,
                    guestPort: guestPort,
                    socketDevice: socketDevice
                )
                try await fwd.start()
                forwarders.append(fwd)
                print(Style.success("✓ 127.0.0.1:\(hostPort) → guest:\(guestPort)"))
            }

            print(Style.dim("Tunnels ready. Ctrl-C to stop."))

            // Clean shutdown on SIGINT / SIGTERM.
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

            let exitSemaphore = DispatchSemaphore(value: 0)
            // The signal handler does the minimum Sendable-
            // safe work: signal the semaphore. The MainActor
            // flow then tears down `forwarders` from its own
            // isolation domain, which satisfies Swift 6 strict
            // concurrency without a lock.
            let onSignal: @Sendable () -> Void = {
                exitSemaphore.signal()
            }
            intSource.setEventHandler(handler: onSignal)
            termSource.setEventHandler(handler: onSignal)
            intSource.resume()
            termSource.resume()

            // Park the process until a signal arrives. We can't
            // `await Task.sleep(for: .seconds(.infinity))`
            // because ArgumentParser isolates `run()` to
            // @MainActor and a sleeping MainActor task blocks
            // the sigsource dispatch. Use a DispatchSemaphore
            // off a background queue to park.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    exitSemaphore.wait()
                    continuation.resume()
                }
            }

            // Back on MainActor after the semaphore fires —
            // tear down the forwarders in the isolation domain
            // that owns them.
            for fwd in forwarders { fwd.stop() }
            print(Style.success("✓ Tunnels closed."))
        }

        /// Parses `<host>:<guest>` into a `(UInt16, UInt16)`.
        /// Rejects unparseable strings and out-of-range ports.
        private func parseMapping(_ input: String) throws -> (UInt16, UInt16) {
            let parts = input.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let host = UInt16(parts[0]),
                  let guest = UInt16(parts[1]),
                  host > 0, guest > 0 else {
                print(Style.error("✗ Invalid mapping '\(input)'. Use <host>:<guest> with ports 1-65535."))
                throw ExitCode.failure
            }
            return (host, guest)
        }
    }
}
