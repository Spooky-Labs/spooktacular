# Runner Lifecycle Engine — Design Spec

**Date:** 2026-04-14
**Status:** Approved
**Author:** WikipediaBrown + Claude

## Context

Spooktacular has a RunnerPool CRD schema, EC2 Mac quickstart, and Prometheus
metrics. The CRD defines the desired state but nothing reconciles it. The
controller can manage individual MacOSVM resources but has no concept of pools,
runner registration, job detection, or recycling.

This spec defines three interconnected systems that turn the RunnerPool schema
into a working CI execution engine:

1. Runner lifecycle state machine
2. GitHub webhook integration
3. Pool recycling with three tiers

## Principles

- **Clean Swift:** All business logic in SpooktacularKit. The controller is a
  thin wrapper that receives events and delegates. No business logic in client
  binaries.
- **Defaults that just work:** Reclone recycling, no pre-warming, runner-exit
  detection. Webhook integration, snapshot restore, agent scrub, and
  pre-warming are opt-in upgrades.
- **Crash-safe:** All state stored in CRD status subresources. Controller
  reconstructs state on restart. No in-memory state survives a crash.
- **Idempotent transitions:** Every state transition checks preconditions
  before acting. Duplicate events are harmless.
- **Apple reference quality:** Simple, well-documented, well-tested. No hacks.

---

## 1. Runner Lifecycle State Machine

### States

Each runner VM in a pool progresses through these states:

```
Requested → Cloning → Booting → Registering → Ready → Busy → Draining → Recycling → [Deleted | → Cloning]
                                                                                         ^
Any state ──timeout/error──▶ Failed ─────────────────────────────────────────────────────┘
```

### State Definitions

| State | What is happening | Timeout | On timeout |
|-------|-------------------|---------|------------|
| Requested | Slot allocated, waiting for node capacity | 60s | Failed |
| Cloning | APFS clone from base on target node | 120s | Failed + cleanup |
| Booting | VM started, waiting for SSH or agent health | 180s | Failed + cleanup |
| Registering | Runner agent installing + registering with CI | 300s | Failed + cleanup |
| Ready | Runner registered, waiting for job assignment | none | — |
| Busy | Job in progress | configurable | — (jobs can be long) |
| Draining | Job finished, runner process exiting | 60s | Force stop |
| Recycling | VM being recloned/restored/scrubbed | 120s | Failed + cleanup |

All timeouts are configurable per-pool via `spec.timeouts`.

### Transition Rules

| Current State | Event | Next State | Side Effects |
|---------------|-------|------------|--------------|
| Requested | node available | Cloning | POST /v1/vms/{name}/clone |
| Requested | timeout | Failed | — |
| Cloning | clone succeeded | Booting | POST /v1/vms/{name}/start |
| Cloning | clone failed | Failed | cleanup node |
| Cloning | timeout | Failed | cleanup node |
| Booting | health check passed | Registering | exec runner install script |
| Booting | boot failed | Failed | stop + delete |
| Booting | timeout | Failed | stop + delete |
| Registering | runner registered | Ready | — |
| Registering | registration failed | Failed | stop + delete + deregister |
| Registering | timeout | Failed | stop + delete |
| Ready | webhook: `in_progress` | Busy | update jobId in status |
| Ready | runner process exited | Failed | deregister + cleanup |
| Busy | webhook: `completed` | Draining | — |
| Busy | runner process exited | Draining | — (ephemeral runners self-exit) |
| Busy | VM stopped unexpectedly | Failed | deregister + cleanup |
| Draining | drain complete | Recycling | deregister runner from GitHub |
| Draining | timeout | Recycling | force stop + deregister |
| Recycling | recycle complete | Cloning | re-register runner (all modes loop back to Cloning) |
| Recycling | recycle failed | Failed | destroy VM |
| Recycling | timeout | Failed | destroy VM |
| Failed | retry < max | Cloning | increment retry, exponential backoff |
| Failed | retry >= max | Deleted | permanent failure, pool creates replacement |

### Implementation

`RunnerStateMachine` is a pure value type in SpooktacularKit:

```swift
public struct RunnerStateMachine: Sendable {
    public enum State: String, Codable, Sendable {
        case requested, cloning, booting, registering
        case ready, busy, draining, recycling
        case failed, deleted
    }

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

    public private(set) var state: State
    public private(set) var retryCount: Int
    public let maxRetries: Int

    public mutating func transition(
        event: Event
    ) -> [SideEffect]
}
```

No I/O, no async, no dependencies. The reconciler calls `transition(event:)`,
gets back a list of side effects, and executes them. Trivially testable.

---

## 2. GitHub Webhook Integration

### Architecture

```
GitHub.com
    │
    │ POST /webhooks/github
    │ X-Hub-Signature-256: sha256=<hex>
    │ X-GitHub-Event: workflow_job
    │ X-GitHub-Delivery: <uuid>
    ▼
Controller (or spook serve)
    │
    ├─ WebhookSignatureVerifier: HMAC-SHA256 check
    ├─ WebhookEvent: parse JSON → typed event
    ├─ EventRouter: match runner name → pool → runner
    └─ RunnerPoolManager: feed event to state machine
```

### Security

1. **HMAC-SHA256 signature verification.** Every webhook carries
   `X-Hub-Signature-256: sha256=<hex>`. The controller computes HMAC of the
   raw body using the shared webhook secret and rejects on mismatch.

2. **Webhook secret storage.** Per-pool secret stored in a Kubernetes Secret
   (referenced by `spec.webhook.secretRef`). For standalone mode, read from
   environment variable `SPOOK_WEBHOOK_SECRET` or file.

3. **Event filtering.** Only `workflow_job` events are processed. All other
   `X-GitHub-Event` types are acknowledged with 200 and ignored.

4. **Replay protection.** `X-GitHub-Delivery` header (unique per delivery)
   tracked in a bounded in-memory set (capacity: 10,000, LRU eviction). The
   controller is idempotent anyway, but this prevents unnecessary
   reconciliation.

### Events That Drive State Transitions

| GitHub event | `action` field | Controller effect |
|---|---|---|
| `workflow_job` | `queued` | Informational. May trigger scale-up if autoscaling. |
| `workflow_job` | `in_progress` | Match `runner_name` → set runner state to Busy |
| `workflow_job` | `completed` | Match `runner_name` → set runner state to Draining |

### Runner Matching

The `workflow_job` payload includes `runner_name` and `runner_id`. During the
Registering phase, the controller records the runner name in the CRD status
(`status.runners[].runnerName`). Webhook events are matched by this name.

### GitHub API Authentication

```swift
public protocol GitHubAuthProvider: Sendable {
    func token() async throws -> String
}
```

Two implementations:

- **GitHubAppAuth:** Exchanges App private key + installation ID for a
  short-lived installation token. Auto-refreshes before expiry. Recommended
  for enterprise.
- **GitHubPATAuth:** Wraps a static personal access token from a Secret or
  environment variable. Simpler setup, long-lived secret.

Both are in SpooktacularKit. The controller injects whichever the user
configured.

### API Calls

| Purpose | Method | Path |
|---|---|---|
| Create registration token | POST | `/repos/{owner}/{repo}/actions/runners/registration-token` |
| Remove runner | DELETE | `/repos/{owner}/{repo}/actions/runners/{runner_id}` |
| List runners | GET | `/repos/{owner}/{repo}/actions/runners` |
| List org runners | GET | `/orgs/{org}/actions/runners` |

### Fallback: Runner-Exit Detection

When no webhook is configured (`spec.webhook` is nil), the controller falls
back to runner-exit detection:

1. GitHub's `--ephemeral` flag causes the runner process to exit after one job.
2. The VM stops (detected via node health polling or PID file absence).
3. The existing MacOSVM reconciler sees the stopped state and notifies the
   RunnerPoolManager.
4. The runner transitions: Busy → Draining → Recycling.

This works out of the box with zero external dependencies. Webhook integration
is an opt-in upgrade for real-time visibility.

### Deployment

The webhook endpoint is added to the controller's existing HTTP listener
(health + metrics). In K8s, exposed via Ingress or LoadBalancer. In standalone
mode, hosted on `spook serve`.

For EC2 Mac behind a private VPC, the recommended path:

```
GitHub.com → ALB (public subnet, TLS) → Controller (private subnet)
```

The ALB terminates TLS and forwards to the controller. The controller verifies
the HMAC signature. Mac nodes are never exposed to the internet.

---

## 3. Pool Recycling

### Three Tiers

| Tier | CRD value | Default | Latency | Guarantee |
|---|---|---|---|---|
| Reclone | `mode: ephemeral` | **Yes** | ~60-90s | Bit-for-bit fresh. New MachineIdentifier, new disk. |
| Snapshot restore | `mode: warm-pool` | Opt-in | ~30-60s | Disk restored to known-good state. Same MachineIdentifier. |
| Agent scrub | `mode: warm-pool-fast` | Opt-in | ~10s | Process-level clean. Same disk, same boot. Documented risk. |

### Recycle Flow (All Tiers)

```
Draining
  │
  ├─ 1. Deregister runner from GitHub (API call)
  │
  ├─ 2. Recycle (tier-specific)
  │     ├─ reclone:  stop VM → delete → APFS clone from base → boot → re-register
  │     ├─ snapshot: stop VM → restore snapshot → boot → re-register
  │     └─ scrub:    exec cleanup script via agent → re-register
  │
  ├─ 3. Validate clean state
  │     ├─ reclone:  boot succeeded + SSH/agent health check
  │     ├─ snapshot: boot succeeded + SSH/agent health check
  │     └─ scrub:    validation script passes
  │
  └─ 4. If validation fails → destroy VM, create fresh replacement
```

### RecycleStrategy Protocol

```swift
public protocol RecycleStrategy: Sendable {
    func recycle(
        vm: String,
        using node: any NodeClient,
        on endpoint: URL
    ) async throws

    func validate(
        vm: String,
        using node: any NodeClient,
        on endpoint: URL
    ) async throws -> Bool
}
```

Three implementations: `RecloneStrategy`, `SnapshotStrategy`, `ScrubStrategy`.
Selected by the reconciler based on `spec.mode`. If `validate` returns false,
the VM is destroyed regardless of strategy.

### Scrub Validation Script (warm-pool-fast)

Executed via guest agent `POST /api/v1/exec` after the cleanup script:

```bash
#!/bin/bash
set -euo pipefail
# No leftover user processes (except system + agent)
user_procs=$(pgrep -u admin -l | grep -v -E 'sshd|spooktacular-agent|loginwindow|Finder' | wc -l)
[ "$user_procs" -eq 0 ] || exit 1

# Runner work directory clean
[ ! -d /Users/admin/actions-runner/_work ] || exit 1

# No leftover env vars
[ -z "${GITHUB_TOKEN:-}" ] || exit 1

# Clipboard empty
clip=$(pbpaste 2>/dev/null || true)
[ -z "$clip" ] || exit 1

echo "CLEAN"
```

Non-zero exit → VM destroyed, never returned to pool dirty.

### Pre-Warming (Opt-In)

Pre-warming clones the next VM while the current job is still running. It:

- Consumes a VM slot (1 of 2 per host) speculatively
- Assumes the next job uses the same `sourceVM` image
- Is wasteful if the pool uses multiple images or jobs are infrequent

Enabled per-pool:

```yaml
spec:
  preWarm: true   # default: false
```

When `preWarm: false` (default), the pool creates the next clone after the
current job finishes. It just works — no wasted slots, no assumptions.

When `preWarm: true`, the controller clones the next VM as soon as a runner
enters Busy state, but only if the node has a free slot.

> **When to enable pre-warming:** Your pool uses a single base image and jobs
> arrive frequently enough that a warm runner is almost always needed. Disable
> it (the default) when jobs are infrequent, your pool uses multiple images, or
> you want to maximize host capacity for other workloads.

---

## 4. Controller Architecture (Clean Swift)

### File Layout

```
SpooktacularKit/ (library — ALL business logic)
├── RunnerStateMachine.swift         pure state transitions, no I/O
├── RecycleStrategy.swift            protocol + RecloneStrategy, SnapshotStrategy, ScrubStrategy
├── RunnerPoolManager.swift          pool sizing, scheduling, event dispatch
├── GitHubRunnerService.swift        registration, deregistration, runner listing
├── GitHubAuthProvider.swift         protocol + GitHubAppAuth, GitHubPATAuth
├── WebhookSignatureVerifier.swift   HMAC-SHA256 verification (pure function)
├── WebhookEvent.swift               parsed event models
└── NodeClient.swift                 protocol for node communication

spook-controller/ (thin K8s client — NO business logic)
├── RunnerPoolReconciler.swift       watches RunnerPool CRDs → calls SpooktacularKit → writes status
└── WebhookEndpoint.swift            receives HTTP → verify → dispatch
```

### Protocol Boundaries

```swift
// NodeClient — abstracts how we talk to Mac nodes
public protocol NodeClient: Sendable {
    func clone(vm: String, from source: String, on node: URL) async throws
    func start(vm: String, on node: URL) async throws
    func stop(vm: String, on node: URL) async throws
    func delete(vm: String, on node: URL) async throws
    func execInGuest(vm: String, command: String, on node: URL) async throws -> ProcessResult
    func health(vm: String, on node: URL) async throws -> Bool
}

// GitHubAuthProvider — abstracts GitHub authentication
public protocol GitHubAuthProvider: Sendable {
    func token() async throws -> String
}

// RecycleStrategy — abstracts recycling behavior
public protocol RecycleStrategy: Sendable {
    func recycle(vm: String, using node: any NodeClient, on endpoint: URL) async throws
    func validate(vm: String, using node: any NodeClient, on endpoint: URL) async throws -> Bool
}
```

The controller injects a concrete `NodeClient` (its `NodeManager` adapted to
the protocol). SpooktacularKit never knows it is running in K8s.

### Concurrency Model

- `RunnerPoolManager` — `actor` in SpooktacularKit
- `RunnerStateMachine` — plain `struct`, called from within the actor
- `GitHubRunnerService` — `actor` (token refresh is thread-safe)
- `RecycleStrategy` implementations — `Sendable` structs
- `RunnerPoolReconciler` — `actor` in spook-controller, owns reference to `RunnerPoolManager`

### Crash Recovery

On startup, the controller:

1. Lists all RunnerPool resources.
2. Lists all MacOSVM resources owned by each pool (via `ownerReferences`).
3. Reads `status.runners[].state` from each pool.
4. Feeds current state into `RunnerStateMachine` for each runner.
5. Executes any pending side effects (e.g., a runner stuck in Registering
   gets its timeout checked).

No in-memory state survives a crash. Everything reconstructed from CRD status.

### Standalone Mode

The same SpooktacularKit code works without K8s. `spook serve` can host the
webhook endpoint. Pool state is stored in JSON files under
`~/.spooktacular/pools/` instead of CRD status. The `RunnerPoolManager`
doesn't know or care where its state lives.

---

## 5. CRD Changes

### RunnerPool Spec Additions

```yaml
spec:
  preWarm: false           # opt-in pre-warming

  timeouts:                # all in seconds, all overridable
    clone: 120
    boot: 180
    register: 300
    drain: 60
    recycle: 120

  retries:
    maxPerRunner: 3        # retries before permanent failure
    backoffBase: 5         # exponential: 5, 10, 20, 40...

  webhook:                 # optional — without this, uses runner-exit detection
    secretRef: "github-webhook-secret"
```

### RunnerPool Status Additions

```yaml
status:
  runners:
    - name: "ios-ci-runners-001"
      state: "Ready"
      runnerName: "spooktacular-ios-ci-runners-001"
      runnerId: 12345
      nodeName: "mac-mini-01"
      ip: "192.168.64.3"
      lastTransition: "2026-04-14T12:00:00Z"
      retryCount: 0
      jobId: null
```

### MacOSVM Additions

```yaml
metadata:
  ownerReferences:
    - apiVersion: spooktacular.app/v1alpha1
      kind: RunnerPool
      name: ios-ci-runners
      uid: <pool-uid>
      controller: true

spec:
  runnerConfig:
    poolName: "ios-ci-runners"
    runnerIndex: 1
    runnerState: "Ready"
```

---

## 6. Testing Strategy

### Unit Tests (SpooktacularKit — fast, no I/O)

| Component | Coverage |
|---|---|
| `RunnerStateMachine` | Every transition, every timeout, every error path. Property test: 1,000 random event sequences, assert no stuck states. |
| `WebhookSignatureVerifier` | Valid/invalid/empty/wrong-algorithm signatures |
| `WebhookEvent` | Parse all `workflow_job` action types, handle missing fields |
| `RecycleStrategy` (reclone) | Correct call order: stop → delete → clone → start. Validation failure triggers destroy. |
| `RecycleStrategy` (snapshot) | Correct call order: stop → restore → start. Validation failure triggers destroy. |
| `RecycleStrategy` (scrub) | Exec cleanup → validate. Validation failure triggers destroy. |
| `RunnerPoolManager` | Scale up when < min, don't exceed max, replace failed, respect preWarm flag |
| `GitHubRunnerService` | Correct API paths, correct auth headers, handle error responses |

### Integration Tests (disabled stubs, require hardware)

| Scenario | Validates |
|---|---|
| Full lifecycle: clone → boot → register → job → drain → reclone | No leaked VMs, no orphan runners |
| Controller crash mid-Registering → restart → resumes | State reconstructed from CRD |
| Webhook replay (same delivery ID twice) | Idempotent handling |
| Pool scale-up under load | Runners created up to maxRunners |
| Node unreachable during recycle | Runner marked Failed, replacement created |
| Scrub validation failure | VM destroyed, never returned dirty |

### Contract Tests (static, run in CI)

| Test | Purpose |
|---|---|
| State machine covers all states | Every enum case has at least one transition test |
| No dead states | Every state is reachable and can exit |
| RecycleStrategy conformance | All three implementations pass same validation suite |
| GitHubAuthProvider conformance | Both App and PAT produce valid auth headers |

### Property Test (the reviewer's benchmark)

Run 1,000 random event sequences through `RunnerStateMachine`. Assert:
- Every runner eventually reaches Deleted or Ready (no stuck states)
- retryCount never exceeds maxRetries
- Deleted is terminal (no transitions out)

This runs in milliseconds because the state machine is a pure struct.

---

## 7. Success Criteria

From the enterprise reviewer:

1. **Kill controller mid-job → recovery works.** Verified by crash recovery
   integration test.
2. **Kill VM mid-job → system reconciles.** Runner transitions to Failed,
   pool creates replacement.
3. **1,000 jobs in a row → no leaked VMs.** Verified by state machine
   property test + integration soak test.
4. **No orphan runners in GitHub UI.** Every Failed/Deleted transition
   includes deregister side effect.
5. **No stuck states after chaos testing.** State machine property test
   proves no dead states exist.
