/// The Spooktacular Kubernetes controller entry point.
///
/// Watches `MacOSVM` custom resources and reconciles them by calling
/// the Spooktacular HTTP API (`spook serve`) on Mac nodes. Runs as a
/// Deployment on a Linux node in the K8s cluster.
///
/// ## Configuration (Environment Variables)
///
/// | Variable | Default | Description |
/// |----------|---------|-------------|
/// | `WATCH_NAMESPACE` | (service account) | Namespace to watch |
/// | `NODE_LABEL_SELECTOR` | `spooktacular.app/role=mac-host` | Mac node selector |
/// | `NODE_API_PORT` | `8484` | Port for `spook serve` |
/// | `HEALTH_CHECK_INTERVAL` | `30` | Seconds between health checks |

import Foundation
import os

// MARK: - Entry Point

@main
struct SpookController {

    private static let logger = Logger(subsystem: "com.spooktacular.controller", category: "main")

    static func main() async {
        logger.notice("spook-controller starting")

        let env = ProcessInfo.processInfo.environment
        let labelSelector = env["NODE_LABEL_SELECTOR"] ?? "spooktacular.app/role=mac-host"
        let apiPort = UInt16(env["NODE_API_PORT"] ?? "") ?? 8484
        let healthInterval = UInt64(env["HEALTH_CHECK_INTERVAL"] ?? "") ?? 30

        let client: KubernetesClient
        do {
            client = try KubernetesClient()
        } catch {
            logger.fault("Failed to create K8s client: \(error.localizedDescription, privacy: .public)")
            return
        }

        let namespace = env["WATCH_NAMESPACE"] ?? client.namespace
        logger.notice("Watching ns=\(namespace, privacy: .public), selector=\(labelSelector, privacy: .public)")

        let nodeManager = NodeManager(apiPort: apiPort, labelSelector: labelSelector)
        let reconciler = Reconciler(client: client, nodeManager: nodeManager)
        let shutdownSignal = ShutdownSignal()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await reconciler.run() }
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(healthInterval))
                    await nodeManager.checkHealth()
                }
            }
            group.addTask {
                await shutdownSignal.wait()
                logger.notice("Shutdown signal received")
            }
            // First task to finish (shutdown signal) triggers cancellation.
            await group.next()
            group.cancelAll()
        }

        logger.notice("spook-controller stopped")
    }
}

// MARK: - ShutdownSignal

/// Bridges POSIX signals (SIGTERM, SIGINT) into Swift concurrency.
final class ShutdownSignal: Sendable {

    private let continuation: AsyncStream<Void>.Continuation
    private let stream: AsyncStream<Void>
    nonisolated(unsafe) private let sources: [any DispatchSourceProtocol]

    init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.stream = stream
        self.continuation = continuation

        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        termSource.setEventHandler { continuation.yield() }
        termSource.resume()

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        intSource.setEventHandler { continuation.yield() }
        intSource.resume()

        self.sources = [termSource, intSource]
    }

    func wait() async {
        for await _ in stream { return }
    }
}

// MARK: - Errors

/// Errors specific to the controller.
enum ControllerError: Error, LocalizedError, Sendable {
    case missingEnvironment(String)
    case missingFile(String)
    case invalidURL(String)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .missingEnvironment(let v): "Missing environment: \(v)"
        case .missingFile(let p):        "Missing file: \(p)"
        case .invalidURL(let u):         "Invalid URL: \(u)"
        case .apiError(let m):           "K8s API error: \(m)"
        }
    }
}
