import ArgumentParser
import Foundation
import SpooktacularKit

extension Spooktacular {

    /// Streams live events from a running VM's host-API Unix-
    /// domain socket to stdout, one event per line.
    ///
    /// Designed for humans at the terminal and for `jq`/`awk`
    /// pipelines in CI. Under the hood it's a ``VMStreamingClient``
    /// pointed at
    /// `~/Library/Application Support/Spooktacular/api/<vm>.sock`
    /// — the same endpoint SwiftUI dashboards hit at 60 fps.
    /// The CLI just decodes every binary-plist frame into JSON
    /// for legibility.
    ///
    /// ## Examples
    ///
    /// ```sh
    /// spooktacular stream my-vm
    /// spooktacular stream my-vm --topic lifecycle
    /// spooktacular stream my-vm --topic metrics --format jsonl | jq .cpuUsage
    /// ```
    struct Stream: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "stream",
            abstract: "Subscribe to a running VM's live event stream.",
            discussion: """
                Connects to the per-VM Unix-domain socket at \
                ~/Library/Application Support/Spooktacular/api/<vm>.sock \
                and prints one JSON line per event.

                Multiple `--topic` flags multiplex onto the same \
                connection. Omitting `--topic` defaults to \
                `metrics`. Topics available:

                  metrics     CPU / memory / load / process count
                  lifecycle   VM state transitions (running, paused, ...)
                  ports       Listening-port discoveries
                  health      Host→guest round-trip latency
                  log         (reserved, future work)

                The server must be running — `spooktacular start` \
                spins it up alongside the VM. Use \
                `spooktacular socket <name>` to print the socket \
                path for ad-hoc `curl --unix-socket` debugging.
                """
        )

        @Argument(help: "Name of the running VM.")
        var name: String

        @Option(
            name: .customLong("topic"),
            help: "Topic to subscribe to. Repeatable for multiplexing."
        )
        var topics: [StreamTopic] = [.metrics]

        func run() async throws {
            let socketURL = try SpooktacularPaths.apiSocketURL(for: name)
            guard FileManager.default.fileExists(atPath: socketURL.path) else {
                print(Style.error("✗ No streaming server for '\(name)'. Is the VM running?"))
                print(Style.dim("  Expected socket at: \(socketURL.path)"))
                throw ExitCode.failure
            }

            let client = VMStreamingClient(socketURL: socketURL)
            try await client.connect()

            // `Sources/spooktacular-cli` is a foreground
            // process. A signal handler breaks the stream
            // loops by cancelling the client; the caller task
            // unwinds cleanly and stdout drains.
            signal(SIGINT, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            source.setEventHandler {
                Task { await client.disconnect() }
            }
            source.resume()

            // Fan out each topic onto its own concurrent
            // subtask. The TaskGroup holds the foreground
            // process open; Ctrl-C cancels them all through
            // the disconnect above.
            try await withThrowingTaskGroup(of: Void.self) { group in
                for topic in topics {
                    group.addTask {
                        try await subscribeAndPrint(topic: topic.protocolTopic, client: client)
                    }
                }
                for try await _ in group { }
            }
        }

        /// Subscribes to `topic`, decodes every frame to the
        /// topic's payload type, re-encodes as JSON, and prints
        /// one line per event.
        private func subscribeAndPrint(
            topic: VMStreamingProtocol.Topic,
            client: VMStreamingClient
        ) async throws {
            let jsonEncoder = JSONEncoder()
            jsonEncoder.dateEncodingStrategy = .iso8601
            jsonEncoder.outputFormatting = [.sortedKeys]

            // Each topic carries a typed payload. Branch once
            // and let the generic path do the rest.
            switch topic {
            case .metrics:
                for try await sample in await client.subscribe(to: .metrics, as: VMMetricsSnapshot.self) {
                    printJSON(topic: topic, value: sample, encoder: jsonEncoder)
                }
            case .lifecycle:
                for try await event in await client.subscribe(to: .lifecycle, as: VMLifecycleEvent.self) {
                    printJSON(topic: topic, value: event, encoder: jsonEncoder)
                }
            case .ports:
                for try await snapshot in await client.subscribe(to: .ports, as: VMPortsSnapshot.self) {
                    printJSON(topic: topic, value: snapshot, encoder: jsonEncoder)
                }
            case .health:
                for try await sample in await client.subscribe(to: .health, as: VMHealthSample.self) {
                    printJSON(topic: topic, value: sample, encoder: jsonEncoder)
                }
            case .log:
                print(Style.warning("Topic 'log' is reserved for future use."))
            }
        }

        private func printJSON<T: Encodable>(
            topic: VMStreamingProtocol.Topic,
            value: T,
            encoder: JSONEncoder
        ) {
            guard let data = try? encoder.encode(value),
                  let line = String(data: data, encoding: .utf8) else {
                return
            }
            print("{\"topic\":\"\(topic.rawValue)\",\"event\":\(line)}")
        }
    }

    /// Prints the Unix-domain-socket path for a VM so users can
    /// pipe arbitrary tooling (curl, socat, shell) at it.
    ///
    /// Mirrors GhostVM's `vmctl socket <name>`.
    struct Socket: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "socket",
            abstract: "Print the Unix-domain-socket path for a running VM.",
            discussion: """
                Writes the socket path for `<name>` to stdout, nothing \
                else. Safe to capture in shell:

                  SOCK=$(spooktacular socket my-vm)
                  curl --unix-socket "$SOCK" http://localhost/v1/…

                Exits 0 whether or not the VM is running — the \
                path is deterministic. Use `spooktacular stream` \
                or `test -S $(spooktacular socket my-vm)` to \
                check liveness.
                """
        )

        @Argument(help: "Name of the VM.")
        var name: String

        func run() async throws {
            let socketURL = try SpooktacularPaths.apiSocketURL(for: name)
            print(socketURL.path)
        }
    }

    /// Topic names accepted on `--topic`. Mirrors
    /// ``VMStreamingProtocol/Topic`` but presents the CLI-
    /// facing spellings `ArgumentParser` can decode as an
    /// enum.
    enum StreamTopic: String, ExpressibleByArgument, CaseIterable {
        case metrics
        case lifecycle
        case ports
        case health
        case log

        var protocolTopic: VMStreamingProtocol.Topic {
            switch self {
            case .metrics: .metrics
            case .lifecycle: .lifecycle
            case .ports: .ports
            case .health: .health
            case .log: .log
            }
        }
    }
}
