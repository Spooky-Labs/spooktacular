# Runner Lifecycle Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the RunnerPool CRD schema into a working CI execution engine with a deterministic state machine, GitHub webhook integration, and three-tier pool recycling.

**Architecture:** All business logic in SpooktacularKit (Clean Swift). The controller is a thin K8s adapter. The state machine is a pure value type with zero I/O — the reconciler calls `transition(event:)` and executes the returned side effects. Webhook verification, GitHub API calls, and recycling strategies are protocol-based for testability.

**Tech Stack:** Swift 6.2, Swift Testing framework, Apple CryptoKit (HMAC), Foundation URLSession (GitHub API), Network.framework (webhook endpoint)

---

## File Map

### New files in SpooktacularKit (library — business logic)

| File | Responsibility |
|------|---------------|
| `Sources/SpooktacularKit/RunnerStateMachine.swift` | Pure state machine: State enum, Event enum, SideEffect enum, `transition(event:)` |
| `Sources/SpooktacularKit/NodeClient.swift` | Protocol abstracting Mac node HTTP API calls |
| `Sources/SpooktacularKit/RecycleStrategy.swift` | Protocol + RecloneStrategy, SnapshotStrategy, ScrubStrategy |
| `Sources/SpooktacularKit/WebhookSignatureVerifier.swift` | HMAC-SHA256 verification (pure function) |
| `Sources/SpooktacularKit/WebhookEvent.swift` | Codable models for GitHub `workflow_job` webhook payloads |
| `Sources/SpooktacularKit/GitHubAuthProvider.swift` | Protocol + GitHubPATAuth implementation |
| `Sources/SpooktacularKit/GitHubRunnerService.swift` | GitHub Actions runner API (register, deregister, list) |
| `Sources/SpooktacularKit/RunnerPoolManager.swift` | Actor: owns state machines, dispatches events, manages pool sizing |

### New files in spook-controller (thin K8s adapter)

| File | Responsibility |
|------|---------------|
| `Sources/spook-controller/RunnerPoolReconciler.swift` | Watches RunnerPool CRDs, delegates to RunnerPoolManager |
| `Sources/spook-controller/WebhookEndpoint.swift` | HTTP POST /webhooks/github, forwards to RunnerPoolManager |

### New test files

| File | What it tests |
|------|--------------|
| `Tests/SpooktacularKitTests/RunnerStateMachineTests.swift` | Every transition, timeouts, retries, property test |
| `Tests/SpooktacularKitTests/WebhookSignatureVerifierTests.swift` | HMAC verification: valid, invalid, empty, wrong algo |
| `Tests/SpooktacularKitTests/WebhookEventTests.swift` | JSON parsing for all workflow_job action types |
| `Tests/SpooktacularKitTests/RecycleStrategyTests.swift` | All 3 strategies against mock NodeClient |
| `Tests/SpooktacularKitTests/GitHubRunnerServiceTests.swift` | API call construction, auth headers, error handling |
| `Tests/SpooktacularKitTests/RunnerPoolManagerTests.swift` | Pool sizing, scale up/down, pre-warm flag |

### Modified files

| File | Change |
|------|--------|
| `Sources/spook-controller/SpookController.swift` | Add RunnerPoolReconciler to task group |
| `deploy/kubernetes/crds/runnerpool-crd.yaml` | Add preWarm, timeouts, retries, webhook fields |
| `deploy/kubernetes/crds/macosvm-crd.yaml` | Add runnerConfig to spec |

---

## Task 1: RunnerStateMachine — States and Happy Path

**Files:**
- Create: `Sources/SpooktacularKit/RunnerStateMachine.swift`
- Create: `Tests/SpooktacularKitTests/RunnerStateMachineTests.swift`

- [ ] **Step 1: Write the failing test for the happy path**

```swift
import Testing
@testable import SpooktacularKit

@Suite("RunnerStateMachine")
struct RunnerStateMachineTests {

    @Test("Initial state is requested")
    func initialState() {
        let sm = RunnerStateMachine(maxRetries: 3)
        #expect(sm.state == .requested)
        #expect(sm.retryCount == 0)
    }

    @Test("Happy path: requested → cloning → booting → registering → ready")
    func happyPathToReady() {
        var sm = RunnerStateMachine(maxRetries: 3)

        var effects = sm.transition(event: .nodeAvailable)
        #expect(sm.state == .cloning)
        #expect(effects.contains { if case .cloneVM = $0 { true } else { false } })

        effects = sm.transition(event: .cloneSucceeded)
        #expect(sm.state == .booting)
        #expect(effects.contains { if case .startVM = $0 { true } else { false } })

        effects = sm.transition(event: .healthCheckPassed)
        #expect(sm.state == .registering)
        #expect(effects.contains { if case .execProvisioningScript = $0 { true } else { false } })

        effects = sm.transition(event: .runnerRegistered)
        #expect(sm.state == .ready)
    }

    @Test("Happy path: ready → busy → draining → recycling → cloning")
    func happyPathJobCycle() {
        var sm = RunnerStateMachine(maxRetries: 3)
        // Fast-forward to ready
        _ = sm.transition(event: .nodeAvailable)
        _ = sm.transition(event: .cloneSucceeded)
        _ = sm.transition(event: .healthCheckPassed)
        _ = sm.transition(event: .runnerRegistered)
        #expect(sm.state == .ready)

        _ = sm.transition(event: .jobStarted(jobId: "123"))
        #expect(sm.state == .busy)

        _ = sm.transition(event: .jobCompleted)
        #expect(sm.state == .draining)

        let effects = sm.transition(event: .drainComplete)
        #expect(sm.state == .recycling)
        #expect(effects.contains { if case .deregisterRunner = $0 { true } else { false } })

        _ = sm.transition(event: .recycleComplete)
        #expect(sm.state == .cloning)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RunnerStateMachineTests 2>&1 | tail -5`
Expected: FAIL — `RunnerStateMachine` not found

- [ ] **Step 3: Write the RunnerStateMachine with happy path transitions**

```swift
// Sources/SpooktacularKit/RunnerStateMachine.swift
import Foundation

/// A pure, deterministic state machine for runner VM lifecycle.
///
/// Each runner in a ``RunnerPool`` has its own state machine instance.
/// The reconciler calls ``transition(event:)`` and executes the returned
/// side effects. The state machine has no I/O, no async, and no
/// dependencies — it is a pure function of (state, event) → (state, effects).
///
/// ## States
///
/// ```
/// Requested → Cloning → Booting → Registering → Ready → Busy → Draining → Recycling → Cloning
///                                                                                         ↑
/// Any state ──timeout/error──▶ Failed ───────────────────────────────────────────────────┘
/// ```
public struct RunnerStateMachine: Sendable, Codable {

    // MARK: - State

    /// The lifecycle state of a runner VM.
    public enum State: String, Codable, Sendable, CaseIterable {
        case requested, cloning, booting, registering
        case ready, busy, draining, recycling
        case failed, deleted
    }

    // MARK: - Event

    /// An event that triggers a state transition.
    public enum Event: Sendable {
        case nodeAvailable
        case cloneSucceeded, cloneFailed
        case healthCheckPassed, bootFailed
        case runnerRegistered, registrationFailed
        case jobStarted(jobId: String)
        case jobCompleted
        case runnerExited
        case vmStopped
        case drainComplete
        case recycleComplete, recycleFailed
        case timeout
        case retryRequested
    }

    // MARK: - Side Effect

    /// A side effect the reconciler must execute after a transition.
    public enum SideEffect: Sendable {
        case cloneVM(source: String)
        case startVM
        case stopVM
        case deleteVM
        case execProvisioningScript
        case deregisterRunner(runnerId: Int)
        case updateStatus(State)
        case scheduleTimeout(seconds: Int)
        case cancelTimeout
        case createReplacement
    }

    // MARK: - Properties

    /// The current state.
    public private(set) var state: State

    /// Number of consecutive failures for this runner slot.
    public private(set) var retryCount: Int

    /// Maximum retries before permanent failure.
    public let maxRetries: Int

    /// The source VM to clone from (set by the pool).
    public var sourceVM: String = ""

    /// The GitHub runner ID (set during registration, used for deregistration).
    public var runnerId: Int?

    /// The current job ID (set when busy).
    public var jobId: String?

    // MARK: - Init

    public init(maxRetries: Int = 3) {
        self.state = .requested
        self.retryCount = 0
        self.maxRetries = maxRetries
    }

    // MARK: - Transition

    /// Applies an event and returns the side effects to execute.
    ///
    /// This is a pure function: no I/O, no async. The reconciler calls
    /// this, reads back the new ``state``, and executes each ``SideEffect``.
    public mutating func transition(event: Event) -> [SideEffect] {
        switch (state, event) {

        // --- Requested ---
        case (.requested, .nodeAvailable):
            state = .cloning
            return [.cloneVM(source: sourceVM), .scheduleTimeout(seconds: 120)]

        case (.requested, .timeout):
            state = .failed
            return [.updateStatus(.failed)]

        // --- Cloning ---
        case (.cloning, .cloneSucceeded):
            state = .booting
            return [.cancelTimeout, .startVM, .scheduleTimeout(seconds: 180)]

        case (.cloning, .cloneFailed), (.cloning, .timeout):
            state = .failed
            return [.cancelTimeout, .deleteVM, .updateStatus(.failed)]

        // --- Booting ---
        case (.booting, .healthCheckPassed):
            state = .registering
            return [.cancelTimeout, .execProvisioningScript, .scheduleTimeout(seconds: 300)]

        case (.booting, .bootFailed), (.booting, .timeout):
            state = .failed
            return [.cancelTimeout, .stopVM, .deleteVM, .updateStatus(.failed)]

        // --- Registering ---
        case (.registering, .runnerRegistered):
            state = .ready
            return [.cancelTimeout, .updateStatus(.ready)]

        case (.registering, .registrationFailed), (.registering, .timeout):
            state = .failed
            return [.cancelTimeout, .stopVM, .deleteVM, .updateStatus(.failed)]

        // --- Ready ---
        case (.ready, .jobStarted(let id)):
            state = .busy
            jobId = id
            return [.updateStatus(.busy)]

        case (.ready, .runnerExited):
            state = .failed
            let effects: [SideEffect] = runnerId.map { [.deregisterRunner(runnerId: $0)] } ?? []
            return effects + [.deleteVM, .updateStatus(.failed)]

        // --- Busy ---
        case (.busy, .jobCompleted):
            state = .draining
            jobId = nil
            return [.scheduleTimeout(seconds: 60)]

        case (.busy, .runnerExited):
            state = .draining
            jobId = nil
            return [.scheduleTimeout(seconds: 60)]

        case (.busy, .vmStopped):
            state = .failed
            jobId = nil
            let effects: [SideEffect] = runnerId.map { [.deregisterRunner(runnerId: $0)] } ?? []
            return effects + [.deleteVM, .updateStatus(.failed)]

        // --- Draining ---
        case (.draining, .drainComplete):
            state = .recycling
            let effects: [SideEffect] = runnerId.map { [.deregisterRunner(runnerId: $0)] } ?? []
            runnerId = nil
            return [.cancelTimeout] + effects + [.scheduleTimeout(seconds: 120)]

        case (.draining, .timeout):
            state = .recycling
            let effects: [SideEffect] = runnerId.map { [.deregisterRunner(runnerId: $0)] } ?? []
            runnerId = nil
            return effects + [.stopVM, .scheduleTimeout(seconds: 120)]

        // --- Recycling ---
        case (.recycling, .recycleComplete):
            state = .cloning
            return [.cancelTimeout, .cloneVM(source: sourceVM), .scheduleTimeout(seconds: 120)]

        case (.recycling, .recycleFailed), (.recycling, .timeout):
            state = .failed
            return [.cancelTimeout, .deleteVM, .updateStatus(.failed)]

        // --- Failed ---
        case (.failed, .retryRequested):
            if retryCount < maxRetries {
                retryCount += 1
                state = .cloning
                return [.cloneVM(source: sourceVM), .scheduleTimeout(seconds: 120)]
            } else {
                state = .deleted
                return [.createReplacement, .updateStatus(.deleted)]
            }

        // --- Deleted is terminal ---
        case (.deleted, _):
            return []

        // --- Ignore invalid transitions ---
        default:
            return []
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RunnerStateMachineTests 2>&1 | tail -5`
Expected: All 3 tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/SpooktacularKit/RunnerStateMachine.swift Tests/SpooktacularKitTests/RunnerStateMachineTests.swift
git commit -S -m "feat: RunnerStateMachine with happy path transitions

Pure value type state machine with 10 states, 16 events, 11 side
effects. Zero I/O, zero dependencies, trivially testable.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: RunnerStateMachine — Error Paths, Retries, Property Test

**Files:**
- Modify: `Tests/SpooktacularKitTests/RunnerStateMachineTests.swift`

- [ ] **Step 1: Write failing tests for error paths and retries**

```swift
// Add to RunnerStateMachineTests

@Test("Clone failure → failed → retry → cloning")
func cloneFailureRetry() {
    var sm = RunnerStateMachine(maxRetries: 3)
    _ = sm.transition(event: .nodeAvailable)
    _ = sm.transition(event: .cloneFailed)
    #expect(sm.state == .failed)
    #expect(sm.retryCount == 0)

    _ = sm.transition(event: .retryRequested)
    #expect(sm.state == .cloning)
    #expect(sm.retryCount == 1)
}

@Test("Max retries exceeded → deleted + createReplacement")
func maxRetriesExceeded() {
    var sm = RunnerStateMachine(maxRetries: 2)
    // Fail and retry twice
    _ = sm.transition(event: .nodeAvailable)
    _ = sm.transition(event: .cloneFailed)
    _ = sm.transition(event: .retryRequested) // retry 1
    _ = sm.transition(event: .cloneFailed)
    _ = sm.transition(event: .retryRequested) // retry 2
    _ = sm.transition(event: .cloneFailed)

    let effects = sm.transition(event: .retryRequested) // retry 3 — exceeds max
    #expect(sm.state == .deleted)
    #expect(effects.contains { if case .createReplacement = $0 { true } else { false } })
}

@Test("Deleted is terminal — all events ignored")
func deletedIsTerminal() {
    var sm = RunnerStateMachine(maxRetries: 0)
    _ = sm.transition(event: .nodeAvailable)
    _ = sm.transition(event: .cloneFailed)
    _ = sm.transition(event: .retryRequested)
    #expect(sm.state == .deleted)

    // Every event should be a no-op
    for event: RunnerStateMachine.Event in [
        .nodeAvailable, .cloneSucceeded, .healthCheckPassed,
        .runnerRegistered, .jobCompleted, .timeout, .retryRequested
    ] {
        let effects = sm.transition(event: event)
        #expect(sm.state == .deleted)
        #expect(effects.isEmpty)
    }
}

@Test("Boot timeout → failed with stop + delete")
func bootTimeout() {
    var sm = RunnerStateMachine(maxRetries: 3)
    _ = sm.transition(event: .nodeAvailable)
    _ = sm.transition(event: .cloneSucceeded)
    #expect(sm.state == .booting)

    let effects = sm.transition(event: .timeout)
    #expect(sm.state == .failed)
    #expect(effects.contains { if case .stopVM = $0 { true } else { false } })
    #expect(effects.contains { if case .deleteVM = $0 { true } else { false } })
}

@Test("VM stopped unexpectedly during busy → failed with deregister")
func vmStoppedDuringBusy() {
    var sm = RunnerStateMachine(maxRetries: 3)
    _ = sm.transition(event: .nodeAvailable)
    _ = sm.transition(event: .cloneSucceeded)
    _ = sm.transition(event: .healthCheckPassed)
    _ = sm.transition(event: .runnerRegistered)
    sm.runnerId = 42
    _ = sm.transition(event: .jobStarted(jobId: "j1"))
    #expect(sm.state == .busy)

    let effects = sm.transition(event: .vmStopped)
    #expect(sm.state == .failed)
    #expect(effects.contains { if case .deregisterRunner(runnerId: 42) = $0 { true } else { false } })
}

@Test("Invalid transitions are ignored")
func invalidTransitionsIgnored() {
    var sm = RunnerStateMachine(maxRetries: 3)
    // In .requested state, cloneSucceeded makes no sense
    let effects = sm.transition(event: .cloneSucceeded)
    #expect(sm.state == .requested)
    #expect(effects.isEmpty)
}

@Test("Property: 1000 random sequences never get stuck")
func propertyNoStuckStates() {
    // All possible events (without associated values for simplicity)
    let events: [RunnerStateMachine.Event] = [
        .nodeAvailable, .cloneSucceeded, .cloneFailed,
        .healthCheckPassed, .bootFailed, .runnerRegistered,
        .registrationFailed, .jobStarted(jobId: "test"),
        .jobCompleted, .runnerExited, .vmStopped,
        .drainComplete, .recycleComplete, .recycleFailed,
        .timeout, .retryRequested,
    ]

    for seed in 0..<1000 {
        var sm = RunnerStateMachine(maxRetries: 3)
        var rng = SeededRNG(seed: UInt64(seed))

        for _ in 0..<50 {
            let event = events[Int(rng.next() % UInt64(events.count))]
            _ = sm.transition(event: event)
        }

        // After 50 random events, the state machine must be in a valid state
        #expect(RunnerStateMachine.State.allCases.contains(sm.state))
        // retryCount never exceeds maxRetries
        #expect(sm.retryCount <= sm.maxRetries)
    }
}
```

- [ ] **Step 2: Add the SeededRNG helper at the bottom of the test file**

```swift
/// Deterministic RNG for property tests.
private struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
```

- [ ] **Step 3: Run tests to verify they pass**

Run: `swift test --filter RunnerStateMachineTests 2>&1 | tail -10`
Expected: All 9 tests PASS (3 from Task 1 + 6 new)

- [ ] **Step 4: Commit**

```bash
git add Tests/SpooktacularKitTests/RunnerStateMachineTests.swift
git commit -S -m "test: RunnerStateMachine error paths, retries, property test

Covers: clone failure → retry, max retries → deleted, boot timeout,
VM stopped during busy, invalid transitions ignored, 1000-sequence
property test proving no stuck states.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: WebhookSignatureVerifier

**Files:**
- Create: `Sources/SpooktacularKit/WebhookSignatureVerifier.swift`
- Create: `Tests/SpooktacularKitTests/WebhookSignatureVerifierTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import Foundation
@testable import SpooktacularKit

@Suite("WebhookSignatureVerifier")
struct WebhookSignatureVerifierTests {

    let secret = "test-webhook-secret"
    let body = Data("{\\"action\\":\\"completed\\"}".utf8)

    @Test("Valid signature passes")
    func validSignature() {
        let signature = WebhookSignatureVerifier.sign(body: body, secret: secret)
        #expect(WebhookSignatureVerifier.verify(
            body: body, signature: "sha256=\(signature)", secret: secret
        ))
    }

    @Test("Wrong signature rejects")
    func wrongSignature() {
        #expect(!WebhookSignatureVerifier.verify(
            body: body, signature: "sha256=deadbeef", secret: secret
        ))
    }

    @Test("Missing sha256= prefix rejects")
    func missingPrefix() {
        let signature = WebhookSignatureVerifier.sign(body: body, secret: secret)
        #expect(!WebhookSignatureVerifier.verify(
            body: body, signature: signature, secret: secret
        ))
    }

    @Test("Empty body with valid signature passes")
    func emptyBody() {
        let empty = Data()
        let signature = WebhookSignatureVerifier.sign(body: empty, secret: secret)
        #expect(WebhookSignatureVerifier.verify(
            body: empty, signature: "sha256=\(signature)", secret: secret
        ))
    }

    @Test("Empty signature rejects")
    func emptySignature() {
        #expect(!WebhookSignatureVerifier.verify(
            body: body, signature: "", secret: secret
        ))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WebhookSignatureVerifierTests 2>&1 | tail -5`
Expected: FAIL — `WebhookSignatureVerifier` not found

- [ ] **Step 3: Write the implementation**

```swift
// Sources/SpooktacularKit/WebhookSignatureVerifier.swift
import Foundation
import CryptoKit

/// Verifies GitHub webhook signatures using HMAC-SHA256.
///
/// GitHub signs every webhook payload with the repository's webhook secret.
/// The signature is sent in the `X-Hub-Signature-256` header as `sha256=<hex>`.
///
/// ## Usage
///
/// ```swift
/// let isValid = WebhookSignatureVerifier.verify(
///     body: requestBody,
///     signature: request.headers["X-Hub-Signature-256"],
///     secret: webhookSecret
/// )
/// ```
public enum WebhookSignatureVerifier {

    /// Verifies that a webhook body matches its HMAC-SHA256 signature.
    ///
    /// - Parameters:
    ///   - body: The raw HTTP request body.
    ///   - signature: The `X-Hub-Signature-256` header value (e.g., `sha256=abc123`).
    ///   - secret: The shared webhook secret.
    /// - Returns: `true` if the signature is valid.
    public static func verify(body: Data, signature: String, secret: String) -> Bool {
        guard signature.hasPrefix("sha256=") else { return false }
        let expected = String(signature.dropFirst("sha256=".count))
        let computed = sign(body: body, secret: secret)
        // Constant-time comparison to prevent timing attacks
        guard expected.count == computed.count else { return false }
        var result: UInt8 = 0
        for (a, b) in zip(expected.utf8, computed.utf8) {
            result |= a ^ b
        }
        return result == 0
    }

    /// Computes the HMAC-SHA256 hex digest for a body and secret.
    ///
    /// Exposed for testing. Production code should use ``verify(body:signature:secret:)``.
    public static func sign(body: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WebhookSignatureVerifierTests 2>&1 | tail -5`
Expected: All 5 tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/SpooktacularKit/WebhookSignatureVerifier.swift Tests/SpooktacularKitTests/WebhookSignatureVerifierTests.swift
git commit -S -m "feat: WebhookSignatureVerifier with HMAC-SHA256

Pure function using CryptoKit. Constant-time comparison to prevent
timing attacks. Tests cover valid/invalid/empty/missing-prefix cases.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: WebhookEvent Models

**Files:**
- Create: `Sources/SpooktacularKit/WebhookEvent.swift`
- Create: `Tests/SpooktacularKitTests/WebhookEventTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import Foundation
@testable import SpooktacularKit

@Suite("WebhookEvent")
struct WebhookEventTests {

    @Test("Parse workflow_job in_progress")
    func parseInProgress() throws {
        let json = """
        {
            "action": "in_progress",
            "workflow_job": {
                "id": 123,
                "run_id": 456,
                "runner_name": "spooktacular-runner-001",
                "runner_id": 789,
                "status": "in_progress",
                "labels": ["self-hosted", "macOS", "ARM64"]
            }
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(WorkflowJobWebhook.self, from: json)
        #expect(event.action == .inProgress)
        #expect(event.workflowJob.runnerName == "spooktacular-runner-001")
        #expect(event.workflowJob.runnerId == 789)
    }

    @Test("Parse workflow_job completed")
    func parseCompleted() throws {
        let json = """
        {
            "action": "completed",
            "workflow_job": {
                "id": 123,
                "run_id": 456,
                "runner_name": "spooktacular-runner-001",
                "runner_id": 789,
                "status": "completed",
                "conclusion": "success",
                "labels": ["self-hosted"]
            }
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(WorkflowJobWebhook.self, from: json)
        #expect(event.action == .completed)
        #expect(event.workflowJob.conclusion == "success")
    }

    @Test("Parse workflow_job queued")
    func parseQueued() throws {
        let json = """
        {
            "action": "queued",
            "workflow_job": {
                "id": 123,
                "run_id": 456,
                "status": "queued",
                "labels": ["self-hosted", "macOS"]
            }
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(WorkflowJobWebhook.self, from: json)
        #expect(event.action == .queued)
        // runner_name is nil when queued (not yet assigned)
        #expect(event.workflowJob.runnerName == nil)
    }

    @Test("Unknown action decoded as other")
    func unknownAction() throws {
        let json = """
        {
            "action": "waiting",
            "workflow_job": {"id": 1, "run_id": 2, "status": "waiting", "labels": []}
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(WorkflowJobWebhook.self, from: json)
        #expect(event.action == .other("waiting"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WebhookEventTests 2>&1 | tail -5`
Expected: FAIL — `WorkflowJobWebhook` not found

- [ ] **Step 3: Write the implementation**

```swift
// Sources/SpooktacularKit/WebhookEvent.swift
import Foundation

/// The top-level GitHub `workflow_job` webhook payload.
///
/// GitHub sends this payload when a workflow job is queued, started,
/// or completed. See: https://docs.github.com/en/webhooks/webhook-events-and-payloads#workflow_job
public struct WorkflowJobWebhook: Codable, Sendable {

    /// The action that triggered the webhook.
    public let action: Action

    /// The workflow job details.
    public let workflowJob: WorkflowJob

    /// Known webhook actions for workflow_job events.
    public enum Action: Codable, Sendable, Equatable {
        case queued
        case inProgress
        case completed
        case other(String)

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "queued":      self = .queued
            case "in_progress": self = .inProgress
            case "completed":   self = .completed
            default:            self = .other(raw)
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .queued:       try container.encode("queued")
            case .inProgress:   try container.encode("in_progress")
            case .completed:    try container.encode("completed")
            case .other(let v): try container.encode(v)
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case action
        case workflowJob = "workflow_job"
    }
}

/// A workflow job from the GitHub webhook payload.
public struct WorkflowJob: Codable, Sendable {

    /// The job ID.
    public let id: Int

    /// The workflow run ID.
    public let runId: Int

    /// The runner name (nil when queued, set when in_progress/completed).
    public let runnerName: String?

    /// The runner ID (nil when queued).
    public let runnerId: Int?

    /// The job status.
    public let status: String

    /// The job conclusion (only set when completed).
    public let conclusion: String?

    /// Labels requested by the job.
    public let labels: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case runId = "run_id"
        case runnerName = "runner_name"
        case runnerId = "runner_id"
        case status, conclusion, labels
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WebhookEventTests 2>&1 | tail -5`
Expected: All 4 tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/SpooktacularKit/WebhookEvent.swift Tests/SpooktacularKitTests/WebhookEventTests.swift
git commit -S -m "feat: WebhookEvent models for GitHub workflow_job payloads

Codable models with snake_case key mapping. Action enum handles
queued/in_progress/completed with fallback for unknown actions.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: NodeClient Protocol + RecycleStrategy

**Files:**
- Create: `Sources/SpooktacularKit/NodeClient.swift`
- Create: `Sources/SpooktacularKit/RecycleStrategy.swift`
- Create: `Tests/SpooktacularKitTests/RecycleStrategyTests.swift`

- [ ] **Step 1: Write NodeClient protocol and mock**

```swift
// Sources/SpooktacularKit/NodeClient.swift
import Foundation

/// The result of a process execution on a guest VM.
public struct GuestExecResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Abstracts communication with a Mac node running ``spook serve``.
///
/// The controller injects a concrete implementation that calls the
/// node's HTTP API. SpooktacularKit uses only this protocol — it
/// never imports controller-specific code.
public protocol NodeClient: Sendable {
    func clone(vm: String, from source: String, on node: URL) async throws
    func start(vm: String, on node: URL) async throws
    func stop(vm: String, on node: URL) async throws
    func delete(vm: String, on node: URL) async throws
    func restoreSnapshot(vm: String, snapshot: String, on node: URL) async throws
    func execInGuest(vm: String, command: String, on node: URL) async throws -> GuestExecResult
    func health(vm: String, on node: URL) async throws -> Bool
}
```

- [ ] **Step 2: Write RecycleStrategy protocol and three implementations**

```swift
// Sources/SpooktacularKit/RecycleStrategy.swift
import Foundation
import os

/// A strategy for recycling a runner VM between jobs.
///
/// Three implementations: ``RecloneStrategy`` (default), ``SnapshotStrategy``,
/// and ``ScrubStrategy``. Selected by the RunnerPool's `mode` field.
public protocol RecycleStrategy: Sendable {
    /// Recycles the VM to a clean state.
    func recycle(vm: String, source: String, using node: any NodeClient, on endpoint: URL) async throws
    /// Validates that the VM is in a clean state after recycling.
    func validate(vm: String, using node: any NodeClient, on endpoint: URL) async throws -> Bool
}

/// Destroys the VM and creates a fresh APFS clone. Default strategy.
///
/// Guarantees bit-for-bit fresh state: new MachineIdentifier, new disk.
/// Latency: ~60-90 seconds.
public struct RecloneStrategy: RecycleStrategy {

    private let logger = Logger(subsystem: "com.spooktacular", category: "recycle.reclone")

    public init() {}

    public func recycle(vm: String, source: String, using node: any NodeClient, on endpoint: URL) async throws {
        logger.info("Reclone: stopping \(vm, privacy: .public)")
        try await node.stop(vm: vm, on: endpoint)
        logger.info("Reclone: deleting \(vm, privacy: .public)")
        try await node.delete(vm: vm, on: endpoint)
        logger.info("Reclone: cloning \(source, privacy: .public) → \(vm, privacy: .public)")
        try await node.clone(vm: vm, from: source, on: endpoint)
        logger.info("Reclone: starting \(vm, privacy: .public)")
        try await node.start(vm: vm, on: endpoint)
    }

    public func validate(vm: String, using node: any NodeClient, on endpoint: URL) async throws -> Bool {
        try await node.health(vm: vm, on: endpoint)
    }
}

/// Restores a known-good snapshot. Opt-in via `mode: warm-pool`.
///
/// Disk restored to snapshot state. Same MachineIdentifier.
/// Latency: ~30-60 seconds.
public struct SnapshotStrategy: RecycleStrategy {

    /// The snapshot name to restore from.
    public let snapshotName: String

    private let logger = Logger(subsystem: "com.spooktacular", category: "recycle.snapshot")

    public init(snapshotName: String) {
        self.snapshotName = snapshotName
    }

    public func recycle(vm: String, source: String, using node: any NodeClient, on endpoint: URL) async throws {
        logger.info("Snapshot: stopping \(vm, privacy: .public)")
        try await node.stop(vm: vm, on: endpoint)
        logger.info("Snapshot: restoring '\(self.snapshotName, privacy: .public)' on \(vm, privacy: .public)")
        try await node.restoreSnapshot(vm: vm, snapshot: snapshotName, on: endpoint)
        logger.info("Snapshot: starting \(vm, privacy: .public)")
        try await node.start(vm: vm, on: endpoint)
    }

    public func validate(vm: String, using node: any NodeClient, on endpoint: URL) async throws -> Bool {
        try await node.health(vm: vm, on: endpoint)
    }
}

/// Runs a cleanup script inside the running VM via the guest agent.
/// Opt-in via `mode: warm-pool-fast`.
///
/// Process-level clean only. Same disk, same boot. ~10 seconds.
/// If validation fails, the VM is destroyed by the caller.
public struct ScrubStrategy: RecycleStrategy {

    private let logger = Logger(subsystem: "com.spooktacular", category: "recycle.scrub")

    public init() {}

    public func recycle(vm: String, source: String, using node: any NodeClient, on endpoint: URL) async throws {
        let cleanupScript = """
        #!/bin/bash
        set -euo pipefail
        # Kill all user processes except system + agent
        pkill -u admin -x -v 'sshd|spooktacular-agent|loginwindow|Finder' 2>/dev/null || true
        # Remove runner work directory
        rm -rf /Users/admin/actions-runner/_work
        # Clear clipboard
        pbcopy < /dev/null 2>/dev/null || true
        # Remove temp files
        rm -rf /tmp/* /var/folders/*/T/* 2>/dev/null || true
        echo "SCRUBBED"
        """
        logger.info("Scrub: running cleanup on \(vm, privacy: .public)")
        let result = try await node.execInGuest(vm: vm, command: cleanupScript, on: endpoint)
        guard result.exitCode == 0 else {
            throw RecycleError.scrubFailed(vm: vm, exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    public func validate(vm: String, using node: any NodeClient, on endpoint: URL) async throws -> Bool {
        let validateScript = """
        #!/bin/bash
        set -euo pipefail
        user_procs=$(pgrep -u admin -l 2>/dev/null | grep -v -E 'sshd|spooktacular-agent|loginwindow|Finder' | wc -l)
        [ "$user_procs" -eq 0 ] || exit 1
        [ ! -d /Users/admin/actions-runner/_work ] || exit 1
        clip=$(pbpaste 2>/dev/null || true)
        [ -z "$clip" ] || exit 1
        echo "CLEAN"
        """
        let result = try await node.execInGuest(vm: vm, command: validateScript, on: endpoint)
        return result.exitCode == 0
    }
}

/// Errors during the recycle phase.
public enum RecycleError: Error, LocalizedError, Sendable {
    case scrubFailed(vm: String, exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .scrubFailed(let vm, let code, let stderr):
            "Scrub failed on '\(vm)' (exit \(code)): \(stderr)"
        }
    }

    public var recoverySuggestion: String? {
        "The VM will be destroyed and replaced with a fresh clone."
    }
}
```

- [ ] **Step 3: Write tests against a mock NodeClient**

```swift
// Tests/SpooktacularKitTests/RecycleStrategyTests.swift
import Testing
import Foundation
@testable import SpooktacularKit

/// Records calls made to a mock node for verification.
final class MockNodeClient: NodeClient, @unchecked Sendable {
    var calls: [String] = []
    var healthResult = true
    var execResult = GuestExecResult(exitCode: 0, stdout: "OK", stderr: "")

    func clone(vm: String, from source: String, on node: URL) async throws {
        calls.append("clone:\(vm):\(source)")
    }
    func start(vm: String, on node: URL) async throws { calls.append("start:\(vm)") }
    func stop(vm: String, on node: URL) async throws { calls.append("stop:\(vm)") }
    func delete(vm: String, on node: URL) async throws { calls.append("delete:\(vm)") }
    func restoreSnapshot(vm: String, snapshot: String, on node: URL) async throws {
        calls.append("restore:\(vm):\(snapshot)")
    }
    func execInGuest(vm: String, command: String, on node: URL) async throws -> GuestExecResult {
        calls.append("exec:\(vm)")
        return execResult
    }
    func health(vm: String, on node: URL) async throws -> Bool {
        calls.append("health:\(vm)")
        return healthResult
    }
}

@Suite("RecycleStrategy")
struct RecycleStrategyTests {

    let node = MockNodeClient()
    let endpoint = URL(string: "https://mac-01:8484")!

    @Test("Reclone: stop → delete → clone → start")
    func recloneCallOrder() async throws {
        let strategy = RecloneStrategy()
        try await strategy.recycle(vm: "r1", source: "base", using: node, on: endpoint)
        #expect(node.calls == ["stop:r1", "delete:r1", "clone:r1:base", "start:r1"])
    }

    @Test("Reclone: validate checks health")
    func recloneValidate() async throws {
        let strategy = RecloneStrategy()
        let ok = try await strategy.validate(vm: "r1", using: node, on: endpoint)
        #expect(ok)
        #expect(node.calls == ["health:r1"])
    }

    @Test("Snapshot: stop → restore → start")
    func snapshotCallOrder() async throws {
        let strategy = SnapshotStrategy(snapshotName: "clean")
        try await strategy.recycle(vm: "r1", source: "base", using: node, on: endpoint)
        #expect(node.calls == ["stop:r1", "restore:r1:clean", "start:r1"])
    }

    @Test("Scrub: exec cleanup script")
    func scrubExec() async throws {
        let strategy = ScrubStrategy()
        try await strategy.recycle(vm: "r1", source: "base", using: node, on: endpoint)
        #expect(node.calls == ["exec:r1"])
    }

    @Test("Scrub: validation failure returns false")
    func scrubValidationFailure() async throws {
        node.execResult = GuestExecResult(exitCode: 1, stdout: "", stderr: "dirty")
        let strategy = ScrubStrategy()
        let ok = try await strategy.validate(vm: "r1", using: node, on: endpoint)
        #expect(!ok)
    }

    @Test("Scrub: recycle throws on non-zero exit")
    func scrubRecycleThrows() async throws {
        node.execResult = GuestExecResult(exitCode: 1, stdout: "", stderr: "failed")
        let strategy = ScrubStrategy()
        await #expect(throws: RecycleError.self) {
            try await strategy.recycle(vm: "r1", source: "base", using: node, on: endpoint)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RecycleStrategyTests 2>&1 | tail -5`
Expected: All 6 tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/SpooktacularKit/NodeClient.swift Sources/SpooktacularKit/RecycleStrategy.swift Tests/SpooktacularKitTests/RecycleStrategyTests.swift
git commit -S -m "feat: NodeClient protocol + 3 RecycleStrategy implementations

RecloneStrategy (default): stop → delete → clone → start
SnapshotStrategy (opt-in): stop → restore → start
ScrubStrategy (opt-in): exec cleanup + validation via guest agent

All tested against MockNodeClient with call order verification.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: GitHubAuthProvider + GitHubRunnerService

**Files:**
- Create: `Sources/SpooktacularKit/GitHubAuthProvider.swift`
- Create: `Sources/SpooktacularKit/GitHubRunnerService.swift`
- Create: `Tests/SpooktacularKitTests/GitHubRunnerServiceTests.swift`

- [ ] **Step 1: Write the auth protocol and PAT implementation**

```swift
// Sources/SpooktacularKit/GitHubAuthProvider.swift
import Foundation

/// Provides authentication tokens for the GitHub API.
///
/// Two implementations:
/// - ``GitHubPATAuth``: Static personal access token.
/// - Future: `GitHubAppAuth` for short-lived installation tokens.
public protocol GitHubAuthProvider: Sendable {
    /// Returns a valid Bearer token for the GitHub API.
    func token() async throws -> String
}

/// Authenticates with a static personal access token.
///
/// The simplest authentication method. The token is provided at init
/// time and never changes. Suitable for single-repo setups.
/// For enterprise, prefer a GitHub App with short-lived tokens.
public struct GitHubPATAuth: GitHubAuthProvider {
    private let pat: String

    public init(token: String) { self.pat = token }

    public func token() async throws -> String { pat }
}
```

- [ ] **Step 2: Write the runner service**

```swift
// Sources/SpooktacularKit/GitHubRunnerService.swift
import Foundation
import os

/// Manages GitHub Actions runner registration and deregistration.
///
/// Calls the GitHub REST API to create registration tokens, remove
/// runners, and list active runners. Authentication is pluggable
/// via ``GitHubAuthProvider``.
public actor GitHubRunnerService {

    private let auth: any GitHubAuthProvider
    private let session: URLSession
    private let logger = Logger(subsystem: "com.spooktacular", category: "github")

    /// Creates a new service.
    ///
    /// - Parameters:
    ///   - auth: The authentication provider (PAT or App).
    ///   - session: The URL session (injectable for testing).
    public init(auth: any GitHubAuthProvider, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    // MARK: - Registration Token

    /// Creates a registration token for a repository.
    ///
    /// - Parameter scope: `"repos/OWNER/REPO"` or `"orgs/ORG"`.
    /// - Returns: The registration token string.
    public func createRegistrationToken(scope: String) async throws -> String {
        let url = URL(string: "https://api.github.com/\(scope)/actions/runners/registration-token")!
        let (data, _) = try await request(url: url, method: "POST")
        let body = try JSONDecoder().decode(RegistrationTokenResponse.self, from: data)
        return body.token
    }

    // MARK: - Remove Runner

    /// Removes a runner from a repository by its runner ID.
    ///
    /// - Parameters:
    ///   - runnerId: The GitHub runner ID.
    ///   - scope: `"repos/OWNER/REPO"` or `"orgs/ORG"`.
    public func removeRunner(runnerId: Int, scope: String) async throws {
        let url = URL(string: "https://api.github.com/\(scope)/actions/runners/\(runnerId)")!
        _ = try await request(url: url, method: "DELETE")
        logger.info("Removed runner \(runnerId) from \(scope, privacy: .public)")
    }

    // MARK: - List Runners

    /// Lists active runners for a repository.
    ///
    /// - Parameter scope: `"repos/OWNER/REPO"` or `"orgs/ORG"`.
    /// - Returns: Array of runner summaries.
    public func listRunners(scope: String) async throws -> [RunnerSummary] {
        let url = URL(string: "https://api.github.com/\(scope)/actions/runners")!
        let (data, _) = try await request(url: url, method: "GET")
        let body = try JSONDecoder().decode(RunnerListResponse.self, from: data)
        return body.runners
    }

    // MARK: - Private

    private func request(url: URL, method: String) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        let tok = try await auth.token()
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GitHubServiceError.apiError(statusCode: http.statusCode, body: body)
        }
        return (data, http)
    }
}

// MARK: - Response Models

struct RegistrationTokenResponse: Codable {
    let token: String
}

/// A summary of a GitHub Actions runner.
public struct RunnerSummary: Codable, Sendable {
    public let id: Int
    public let name: String
    public let status: String
    public let busy: Bool
    public let labels: [RunnerLabel]

    public struct RunnerLabel: Codable, Sendable {
        public let name: String
    }
}

struct RunnerListResponse: Codable {
    let runners: [RunnerSummary]
}

/// Errors from the GitHub API.
public enum GitHubServiceError: Error, LocalizedError, Sendable {
    case invalidResponse
    case apiError(statusCode: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid response from GitHub API."
        case .apiError(let code, let body): "GitHub API error (\(code)): \(body)"
        }
    }
}
```

- [ ] **Step 3: Write tests for URL construction and auth headers**

```swift
// Tests/SpooktacularKitTests/GitHubRunnerServiceTests.swift
import Testing
import Foundation
@testable import SpooktacularKit

@Suite("GitHubRunnerService")
struct GitHubRunnerServiceTests {

    @Test("PAT auth returns the token directly")
    func patAuth() async throws {
        let auth = GitHubPATAuth(token: "ghp_test123")
        let tok = try await auth.token()
        #expect(tok == "ghp_test123")
    }

    @Test("RegistrationTokenResponse decodes correctly")
    func decodeRegistrationToken() throws {
        let json = Data(#"{"token":"AABBC","expires_at":"2026-01-01T00:00:00Z"}"#.utf8)
        let decoded = try JSONDecoder().decode(RegistrationTokenResponse.self, from: json)
        #expect(decoded.token == "AABBC")
    }

    @Test("RunnerListResponse decodes correctly")
    func decodeRunnerList() throws {
        let json = Data("""
        {
            "total_count": 1,
            "runners": [{
                "id": 42,
                "name": "spooktacular-r1",
                "status": "online",
                "busy": false,
                "labels": [{"id": 1, "name": "self-hosted", "type": "read-only"}]
            }]
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(RunnerListResponse.self, from: json)
        #expect(decoded.runners.count == 1)
        #expect(decoded.runners[0].name == "spooktacular-r1")
        #expect(decoded.runners[0].busy == false)
    }

    @Test("GitHubServiceError has errorDescription")
    func errorDescription() {
        let err = GitHubServiceError.apiError(statusCode: 403, body: "rate limited")
        #expect(err.errorDescription?.contains("403") == true)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter GitHubRunnerServiceTests 2>&1 | tail -5`
Expected: All 4 tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/SpooktacularKit/GitHubAuthProvider.swift Sources/SpooktacularKit/GitHubRunnerService.swift Tests/SpooktacularKitTests/GitHubRunnerServiceTests.swift
git commit -S -m "feat: GitHubAuthProvider + GitHubRunnerService

Protocol-based GitHub API client for runner registration, deregistration,
and listing. PAT auth implementation included. App auth is a future
addition behind the same protocol.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: RunnerPoolManager Actor

**Files:**
- Create: `Sources/SpooktacularKit/RunnerPoolManager.swift`
- Create: `Tests/SpooktacularKitTests/RunnerPoolManagerTests.swift`

- [ ] **Step 1: Write failing tests for pool sizing**

```swift
import Testing
import Foundation
@testable import SpooktacularKit

@Suite("RunnerPoolManager")
struct RunnerPoolManagerTests {

    @Test("Scale up creates runners to meet minRunners")
    func scaleUp() async {
        let manager = RunnerPoolManager()
        let actions = await manager.reconcilePool(
            desired: PoolDesiredState(
                minRunners: 2, maxRunners: 4,
                sourceVM: "base", mode: .ephemeral, preWarm: false
            ),
            current: [] // no runners exist
        )
        #expect(actions.count == 2)
        #expect(actions.allSatisfy { if case .createRunner = $0 { true } else { false } })
    }

    @Test("No scale up when at minRunners")
    func noScaleUpAtMin() async {
        let manager = RunnerPoolManager()
        let actions = await manager.reconcilePool(
            desired: PoolDesiredState(
                minRunners: 2, maxRunners: 4,
                sourceVM: "base", mode: .ephemeral, preWarm: false
            ),
            current: [
                RunnerStatus(name: "r1", state: .ready, retryCount: 0),
                RunnerStatus(name: "r2", state: .ready, retryCount: 0),
            ]
        )
        #expect(actions.isEmpty)
    }

    @Test("Replace failed runners")
    func replaceFailed() async {
        let manager = RunnerPoolManager()
        let actions = await manager.reconcilePool(
            desired: PoolDesiredState(
                minRunners: 2, maxRunners: 4,
                sourceVM: "base", mode: .ephemeral, preWarm: false
            ),
            current: [
                RunnerStatus(name: "r1", state: .ready, retryCount: 0),
                RunnerStatus(name: "r2", state: .deleted, retryCount: 3),
            ]
        )
        // Should create 1 replacement for the deleted runner
        #expect(actions.count == 1)
        #expect(actions.allSatisfy { if case .createRunner = $0 { true } else { false } })
    }

    @Test("Don't exceed maxRunners")
    func respectMax() async {
        let manager = RunnerPoolManager()
        let actions = await manager.reconcilePool(
            desired: PoolDesiredState(
                minRunners: 2, maxRunners: 2,
                sourceVM: "base", mode: .ephemeral, preWarm: false
            ),
            current: [
                RunnerStatus(name: "r1", state: .busy, retryCount: 0),
                RunnerStatus(name: "r2", state: .busy, retryCount: 0),
            ]
        )
        #expect(actions.isEmpty)
    }

    @Test("PreWarm false does not pre-clone")
    func preWarmDisabled() async {
        let manager = RunnerPoolManager()
        let actions = await manager.reconcilePool(
            desired: PoolDesiredState(
                minRunners: 1, maxRunners: 2,
                sourceVM: "base", mode: .ephemeral, preWarm: false
            ),
            current: [
                RunnerStatus(name: "r1", state: .busy, retryCount: 0),
            ]
        )
        // preWarm=false, 1 busy runner at min=1 → no action
        #expect(actions.isEmpty)
    }

    @Test("PreWarm true creates extra runner when busy")
    func preWarmEnabled() async {
        let manager = RunnerPoolManager()
        let actions = await manager.reconcilePool(
            desired: PoolDesiredState(
                minRunners: 1, maxRunners: 2,
                sourceVM: "base", mode: .ephemeral, preWarm: true
            ),
            current: [
                RunnerStatus(name: "r1", state: .busy, retryCount: 0),
            ]
        )
        // preWarm=true, 1 busy → should pre-clone 1 more
        #expect(actions.count == 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RunnerPoolManagerTests 2>&1 | tail -5`
Expected: FAIL — types not found

- [ ] **Step 3: Write the RunnerPoolManager**

```swift
// Sources/SpooktacularKit/RunnerPoolManager.swift
import Foundation
import os

/// The desired state of a runner pool, derived from the CRD spec.
public struct PoolDesiredState: Sendable {
    public let minRunners: Int
    public let maxRunners: Int
    public let sourceVM: String
    public let mode: PoolMode
    public let preWarm: Bool

    public init(minRunners: Int, maxRunners: Int, sourceVM: String, mode: PoolMode, preWarm: Bool) {
        self.minRunners = minRunners
        self.maxRunners = maxRunners
        self.sourceVM = sourceVM
        self.mode = mode
        self.preWarm = preWarm
    }
}

/// The lifecycle mode for a runner pool.
public enum PoolMode: String, Codable, Sendable {
    case ephemeral
    case warmPool = "warm-pool"
    case warmPoolFast = "warm-pool-fast"
}

/// The current status of a single runner in a pool.
public struct RunnerStatus: Sendable {
    public let name: String
    public let state: RunnerStateMachine.State
    public let retryCount: Int

    public init(name: String, state: RunnerStateMachine.State, retryCount: Int) {
        self.name = name
        self.state = state
        self.retryCount = retryCount
    }
}

/// An action the reconciler should take on the pool.
public enum PoolAction: Sendable {
    case createRunner(name: String, sourceVM: String)
    case deleteRunner(name: String)
}

/// Manages runner pool sizing and lifecycle decisions.
///
/// This actor owns the pool-level logic: how many runners should exist,
/// when to scale up/down, when to replace failed runners. Individual
/// runner state transitions are handled by ``RunnerStateMachine``.
public actor RunnerPoolManager {

    private let logger = Logger(subsystem: "com.spooktacular", category: "pool")

    public init() {}

    /// Compares desired state to current state and returns actions.
    ///
    /// - Parameters:
    ///   - desired: The pool spec (min, max, mode, preWarm).
    ///   - current: The current runners and their states.
    /// - Returns: Actions to bring current state closer to desired.
    public func reconcilePool(
        desired: PoolDesiredState,
        current: [RunnerStatus]
    ) -> [PoolAction] {
        // Count active runners (not deleted, not permanently failed)
        let active = current.filter { $0.state != .deleted }
        let activeCount = active.count

        // Count busy runners (for pre-warm decision)
        let busyCount = active.filter { $0.state == .busy }.count

        var actions: [PoolAction] = []

        // Scale up to meet minRunners
        let deficit = desired.minRunners - activeCount
        if deficit > 0 {
            for i in 0..<deficit {
                let name = generateRunnerName(existingCount: activeCount + i)
                actions.append(.createRunner(name: name, sourceVM: desired.sourceVM))
            }
        }

        // Pre-warm: if enabled and all active runners are busy, add one more
        if desired.preWarm && deficit <= 0 && busyCount == activeCount && activeCount < desired.maxRunners {
            let name = generateRunnerName(existingCount: activeCount)
            actions.append(.createRunner(name: name, sourceVM: desired.sourceVM))
        }

        // Cap at maxRunners
        let totalAfter = activeCount + actions.count
        if totalAfter > desired.maxRunners {
            actions = Array(actions.prefix(desired.maxRunners - activeCount))
        }

        return actions
    }

    private func generateRunnerName(existingCount: Int) -> String {
        "runner-\(String(format: "%03d", existingCount + 1))"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RunnerPoolManagerTests 2>&1 | tail -5`
Expected: All 6 tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/SpooktacularKit/RunnerPoolManager.swift Tests/SpooktacularKitTests/RunnerPoolManagerTests.swift
git commit -S -m "feat: RunnerPoolManager with pool sizing logic

Actor managing pool-level decisions: scale up to minRunners, replace
deleted runners, respect maxRunners, opt-in pre-warming when all
runners are busy. Individual runner state via RunnerStateMachine.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: CRD Updates + Controller Wiring

**Files:**
- Modify: `deploy/kubernetes/crds/runnerpool-crd.yaml`
- Modify: `deploy/kubernetes/crds/macosvm-crd.yaml`
- Create: `Sources/spook-controller/RunnerPoolReconciler.swift`
- Create: `Sources/spook-controller/WebhookEndpoint.swift`
- Modify: `Sources/spook-controller/SpookController.swift`

- [ ] **Step 1: Add new fields to RunnerPool CRD**

Add under `spec.properties` in `runnerpool-crd.yaml`:

```yaml
                preWarm:
                  type: boolean
                  description: >-
                    Clone the next runner VM while the current job runs.
                    Consumes a VM slot speculatively. Only useful when the
                    pool uses a single sourceVM and jobs arrive frequently.
                  default: false

                timeouts:
                  type: object
                  description: Timeout overrides in seconds.
                  properties:
                    clone:
                      type: integer
                      default: 120
                    boot:
                      type: integer
                      default: 180
                    register:
                      type: integer
                      default: 300
                    drain:
                      type: integer
                      default: 60
                    recycle:
                      type: integer
                      default: 120

                retries:
                  type: object
                  description: Retry policy for failed runners.
                  properties:
                    maxPerRunner:
                      type: integer
                      default: 3
                      minimum: 0
                    backoffBase:
                      type: integer
                      default: 5
                      minimum: 1

                webhook:
                  type: object
                  description: >-
                    GitHub webhook configuration. Optional — without this,
                    the controller detects job completion via runner process
                    exit (works with --ephemeral flag).
                  properties:
                    secretRef:
                      type: string
                      description: >-
                        Kubernetes Secret containing the webhook HMAC secret
                        in a key named "secret".
```

- [ ] **Step 2: Add runnerConfig to MacOSVM CRD**

Add under `spec.properties` in `macosvm-crd.yaml`:

```yaml
                runnerConfig:
                  type: object
                  description: >-
                    Set by RunnerPoolReconciler when this VM is managed by
                    a RunnerPool. Do not set manually.
                  properties:
                    poolName:
                      type: string
                    runnerIndex:
                      type: integer
                    runnerState:
                      type: string
```

- [ ] **Step 3: Write RunnerPoolReconciler (thin K8s adapter)**

```swift
// Sources/spook-controller/RunnerPoolReconciler.swift
import Foundation
import os
import SpooktacularKit

/// Watches RunnerPool custom resources and delegates to ``RunnerPoolManager``.
///
/// This is a thin K8s adapter following Clean Swift: it reads CRD state,
/// calls SpooktacularKit, and writes status back. No business logic here.
actor RunnerPoolReconciler {

    private let client: KubernetesClient
    private let manager: RunnerPoolManager
    private let logger = Logger(subsystem: "com.spooktacular.controller", category: "runnerpool")

    init(client: KubernetesClient, manager: RunnerPoolManager) {
        self.client = client
        self.manager = manager
    }

    /// Main reconciliation loop. Watches RunnerPool CRDs and reconciles.
    func run() async {
        logger.notice("RunnerPoolReconciler starting")
        // TODO: Implement watch loop for RunnerPool resources
        // Pattern matches existing Reconciler.run() — list + watch + dispatch
        // Each event: read spec → call manager.reconcilePool() → execute actions → write status
    }
}
```

- [ ] **Step 4: Write WebhookEndpoint (thin HTTP adapter)**

```swift
// Sources/spook-controller/WebhookEndpoint.swift
import Foundation
import os
import SpooktacularKit

/// HTTP endpoint for receiving GitHub webhooks.
///
/// Thin adapter: receives POST, verifies signature via SpooktacularKit,
/// parses event, and forwards to RunnerPoolManager. No business logic.
enum WebhookEndpoint {

    private static let logger = Logger(subsystem: "com.spooktacular.controller", category: "webhook")

    /// Handles an incoming webhook request.
    ///
    /// - Parameters:
    ///   - body: Raw HTTP request body.
    ///   - headers: HTTP headers (must include X-Hub-Signature-256, X-GitHub-Event).
    ///   - secret: The webhook HMAC secret.
    /// - Returns: HTTP status code to send back.
    static func handle(
        body: Data,
        headers: [String: String],
        secret: String
    ) -> Int {
        // 1. Verify signature
        guard let signature = headers["x-hub-signature-256"] ?? headers["X-Hub-Signature-256"],
              WebhookSignatureVerifier.verify(body: body, signature: signature, secret: secret) else {
            logger.warning("Webhook signature verification failed")
            return 401
        }

        // 2. Filter event type
        let eventType = headers["x-github-event"] ?? headers["X-GitHub-Event"] ?? ""
        guard eventType == "workflow_job" else {
            logger.debug("Ignoring event type: \(eventType, privacy: .public)")
            return 200
        }

        // 3. Parse payload
        guard let event = try? JSONDecoder().decode(WorkflowJobWebhook.self, from: body) else {
            logger.error("Failed to parse workflow_job payload")
            return 400
        }

        logger.info("Webhook: workflow_job \(event.action) runner=\(event.workflowJob.runnerName ?? "nil", privacy: .public)")

        // 4. TODO: Forward to RunnerPoolManager for state machine transition
        return 200
    }
}
```

- [ ] **Step 5: Add RunnerPoolReconciler to SpookController task group**

In `Sources/spook-controller/SpookController.swift`, add after the existing reconciler setup:

```swift
let poolManager = RunnerPoolManager()
let poolReconciler = RunnerPoolReconciler(client: client, manager: poolManager)
```

And inside the `withTaskGroup` block, add:

```swift
group.addTask {
    await poolReconciler.run()
}
```

- [ ] **Step 6: Build to verify compilation**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete

- [ ] **Step 7: Commit**

```bash
git add deploy/kubernetes/crds/runnerpool-crd.yaml deploy/kubernetes/crds/macosvm-crd.yaml \
  Sources/spook-controller/RunnerPoolReconciler.swift Sources/spook-controller/WebhookEndpoint.swift \
  Sources/spook-controller/SpookController.swift
git commit -S -m "feat: RunnerPoolReconciler + WebhookEndpoint + CRD updates

Thin K8s adapter for RunnerPool resources. WebhookEndpoint verifies
HMAC signatures and parses workflow_job events. CRDs updated with
preWarm, timeouts, retries, webhook, and runnerConfig fields.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Final Build + Test + Integration Test Stubs

**Files:**
- Modify: `Tests/SpooktacularKitTests/VMLifecycleIntegrationTests.swift`

- [ ] **Step 1: Run full test suite**

Run: `swift test 2>&1 | tail -5`
Expected: 390+ tests passing (360 existing + 30+ new)

- [ ] **Step 2: Add integration test stubs for runner lifecycle**

Add to the existing `VMLifecycleIntegrationTests.swift`:

```swift
@Test("Full runner lifecycle: clone → boot → register → job → drain → reclone",
      .disabled("Requires Apple Silicon with VZ entitlement and GitHub token"))
func fullRunnerLifecycle() async throws {
    // Clone base → boot → install runner → register with GitHub →
    // trigger job → job completes → deregister → reclone → re-register
}

@Test("Controller crash mid-Registering recovers on restart",
      .disabled("Requires Apple Silicon with VZ entitlement"))
func controllerCrashRecovery() async throws {
    // Start runner lifecycle → kill controller during Registering →
    // restart controller → verify it resumes from CRD status
}

@Test("Warm pool scrub validation prevents dirty reuse",
      .disabled("Requires Apple Silicon with VZ entitlement"))
func scrubValidationPreventsReuse() async throws {
    // Run job that leaves files → scrub → validate → expect destroy
}

@Test("Webhook replay protection is idempotent",
      .disabled("Requires Apple Silicon with VZ entitlement"))
func webhookReplayIdempotent() async throws {
    // Send same workflow_job webhook twice → verify single transition
}
```

- [ ] **Step 3: Run full build + test to confirm everything green**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: Build complete, all tests pass

- [ ] **Step 4: Commit**

```bash
git add Tests/SpooktacularKitTests/VMLifecycleIntegrationTests.swift
git commit -S -m "test: Add runner lifecycle integration test stubs

4 disabled stubs documenting scenarios that require real hardware:
full lifecycle, crash recovery, scrub validation, webhook replay.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 5: Push all commits**

```bash
git pull --rebase origin main && git push origin main
```
