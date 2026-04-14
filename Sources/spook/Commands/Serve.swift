import ArgumentParser
import Foundation
import SpooktacularKit

extension Spook {

    /// Starts an HTTP API server for managing VMs programmatically.
    ///
    /// The server exposes a RESTful JSON API for listing, creating,
    /// starting, stopping, and deleting virtual machines. It binds to
    /// localhost by default and uses plain HTTP (no TLS).
    ///
    /// Use a reverse proxy (e.g., Caddy, nginx) if you need TLS or
    /// authentication in production.
    ///
    /// ## Endpoints
    ///
    /// | Method | Path | Description |
    /// |--------|------|-------------|
    /// | `GET` | `/health` | Health check |
    /// | `GET` | `/v1/vms` | List all VMs |
    /// | `GET` | `/v1/vms/:name` | Get VM details |
    /// | `POST` | `/v1/vms` | Create a new VM (requires IPSW; prefer clone) |
    /// | `POST` | `/v1/vms/:name/clone` | Clone a VM from a base image |
    /// | `POST` | `/v1/vms/:name/start` | Start a VM |
    /// | `POST` | `/v1/vms/:name/stop` | Stop a VM |
    /// | `DELETE` | `/v1/vms/:name` | Delete a VM |
    /// | `GET` | `/v1/vms/:name/ip` | Resolve VM IP |
    struct Serve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start an HTTP API server for VM management.",
            discussion: """
                Starts a lightweight HTTP API server that exposes \
                RESTful endpoints for managing virtual machines \
                programmatically. The server binds to localhost by \
                default and uses plain HTTP.

                Use a reverse proxy for TLS and authentication.

                The server responds with JSON in a consistent format:
                  {"status": "ok", "data": {...}}
                  {"status": "error", "message": "..."}

                EXAMPLES:
                  spook serve
                  spook serve --port 9090
                  spook serve --host 0.0.0.0 --port 8484
                """
        )

        @Option(help: "TCP port to listen on.")
        var port: Int = Int(HTTPAPIServer.defaultPort)

        @Option(help: "Host address to bind to. Use 0.0.0.0 for all interfaces.")
        var host: String = "127.0.0.1"

        @Option(help: "Path to the spook binary for spawning VM processes.")
        var spookPath: String = ProcessInfo.processInfo.environment["SPOOK_PATH"] ?? HTTPAPIServer.defaultSpookPath

        func run() async throws {
            try SpooktacularPaths.ensureDirectories()

            guard port > 0 && port <= 65535 else {
                print(Style.error("Invalid port \(port). Must be between 1 and 65535."))
                throw ExitCode.failure
            }

            let server: HTTPAPIServer
            do {
                server = try HTTPAPIServer(
                    host: host,
                    port: UInt16(port),
                    vmDirectory: SpooktacularPaths.vms,
                    spookPath: spookPath
                )
            } catch {
                print(Style.error("Failed to create server: \(error.localizedDescription)"))
                throw ExitCode.failure
            }

            let shutdownServer = server
            for sig in [SIGTERM, SIGINT] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                source.setEventHandler {
                    let sigName = sig == SIGTERM ? "SIGTERM" : "SIGINT"
                    print("\nReceived \(sigName) — shutting down API server...")
                    Task {
                        await shutdownServer.stop()
                        Foundation.exit(0)
                    }
                }
                source.resume()
            }

            print(Style.bold("Spooktacular HTTP API Server"))
            print()
            Style.field("Endpoint", "http://\(host):\(port)")
            Style.field("VM directory", Style.dim(SpooktacularPaths.vms.path))
            print()
            print(Style.dim("Press Ctrl+C to stop."))
            print()

            do {
                try await server.start()
            } catch {
                print(Style.error("Server failed to start: \(error.localizedDescription)"))
                throw ExitCode.failure
            }

            try await Task.sleep(for: .seconds(Double(Int.max)))
        }
    }
}
