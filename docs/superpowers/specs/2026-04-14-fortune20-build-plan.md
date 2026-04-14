# Fortune-20 Build Plan — Staff Engineer Implementation Packet

**Date:** 2026-04-14
**Status:** Approved
**Source:** Enterprise reviewer

## Six Invariants

Every engineering decision must preserve these:

1. No production control-plane call without mTLS.
2. No VM returned to a warm pool without positive scrub validation.
3. No runner considered Ready until both guest control and GitHub registration are confirmed.
4. No break-glass operation without separate scope and audit.
5. No domain logic in Apple-framework adapters.
6. No Apple-framework types in domain objects.

## Package.swift Target Split

Split SpooktacularKit into:

| Target | Contents | Imports |
|--------|----------|---------|
| SpookCore | Value objects (VMID, RunnerID, NodeID), enums (RunnerPhase, HostDrainState, AuthScope), policies (WarmPoolPolicy, EphemeralPolicy, TLSMode) | Foundation only |
| SpookApplication | Protocols (VirtualMachineRuntime, GuestControlChannel, RunnerRegistry, NodeControlPlane, CredentialStore, AuditSink), use cases (ProvisionRunnerVM, RegisterRunner, ScrubVM, DestroyVM, ReconcileRunnerPool) | SpookCore only |
| SpookInfrastructureApple | VZ*, NWProtocolTLS, Security, OSLog, ServiceManagement adapters | SpookApplication + Apple frameworks |
| SpookInfrastructureGitHub | GitHub REST client, webhook/event adapters | SpookApplication + Foundation |
| SpookInfrastructureKubernetes | CRD models, watch/list clients, status patching | SpookApplication + Foundation |
| Executables | spook, Spooktacular, spook-controller, spooktacular-agent | Thin composition roots |

## Three Parallel Tracks

### Track 1: Identity and Control-Plane Safety
- KeychainIdentityStore
- MutualTLSURLSessionFactory
- MutualTLSListenerFactory  
- CertificateReloader
- APIs: NWProtocolTLS.Options, NWParameters, URLSessionDelegate, SecItemAdd/Copy/Update

### Track 2: Runner Lifecycle and Clean Reset
- VirtualMachineRuntime adapter (wraps all VZ* types)
- Complete RunnerPoolReconciler state machine (13 states)
- WarmPoolScrubCoordinator with VirtioFS cleanup share
- RunnerRegistrationCoordinator with GitHub API
- APIs: VZVirtualMachine, VZVirtualMachineConfiguration, VZMacOSInstaller, VZVirtioFileSystemDeviceConfiguration

### Track 3: Observability and Auditability
- OSSignposter on every lifecycle phase
- Structured logs with request/job/VM IDs
- Metrics by lifecycle and pool
- APIs: Logger, OSSignposter

## State Machine (13 states)

```
Pending → CloningBase → ConfiguringVM → Booting → GuestControlReady →
RunnerRegistering → RunnerIdle → RunnerBusy → RunnerDeregistering →
Scrubbing → ScrubValidating → ReturnedToPool | Destroyed | Failed
```

## Files to Create/Extract

From RunnerPoolReconciler.swift:
- RunnerPoolAutoscaler.swift
- RunnerRegistrationCoordinator.swift
- WarmPoolScrubCoordinator.swift
- RunnerTimeoutScheduler.swift

From HTTPAPIServer.swift:
- HTTPRequestDecoder.swift
- HTTPResponseEncoder.swift
- NodeCommandRouter.swift
- NodeAuthMiddleware.swift
- NodeAuditMiddleware.swift

From AgentRouter.swift:
- AgentAuthorizationPolicy.swift
- AgentCommandCatalog.swift
- AgentAuditLogger.swift
- BreakGlassPolicy.swift

New:
- VirtualMachineRuntime.swift (Infrastructure/Apple)
- NodeControlPlaneClient.swift
- VMLifecycleCoordinator.swift
- StatusPatchService.swift
- DeletionCoordinator.swift

## Acceptance Criteria

1. 1,000 GitHub jobs, zero leaked VMs, zero stale GitHub runners
2. Wrong cert fails even with right token
3. Cert rotation without dropping to insecure mode
4. No private keys in argv, shell history, or world-readable files
5. Secret written by one workflow absent in the next
6. Scrub crash never returns VM to pool
7. Runner token cannot invoke shell
8. Operator can answer "why is CI slower today?" from dashboards alone
