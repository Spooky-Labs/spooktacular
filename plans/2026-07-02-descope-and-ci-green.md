# Descope + CI Green Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the six embedded non-core subsystems (~35k LOC), purge fiction-tier docs, and make CI (PR #48) green for the first time since 2026-04-20 — while `swift build` and `swift test` stay green after every task.

**Architecture:** Pure subtraction in dependency order. Each task removes one subsystem plus every inbound reference, test, doc citation, and `SecurityControlInventory` entry in the same commit, so the tree compiles and the full test suite passes at every commit boundary. No new features. Line numbers cited below are valid at HEAD `30b473bb2` and WILL drift as tasks land — every edit step therefore starts from a `grep`, not a line number.

**Tech Stack:** Swift 6 / SwiftPM, SwiftLint 0.63.2 (`--strict`), GitHub Actions (macos-26), fastlane.

## Global Constraints

- After EVERY task: `swift build` exit 0 AND `swift test --parallel --skip SpooktacularUITests` reports `passed` (no failures). Commit only when both hold.
- KEEP-set (never delete in this plan): `RunnerStateMachine`, `GitHubRunnerService`, `GitHubRunnerTemplate`, `GitHubTokenResolution`, `RunnerPoolManager`, `FairScheduler`, `WorkflowJobWebhook` (in `WebhookEvent.swift`), `WebhookSignatureVerifier`, `KeychainTLSProvider`, `ScrubStrategy`/`RecloneStrategy`/`SnapshotStrategy`/`RecycleStrategy`/`NodeClient`, `NBDAttachmentMonitor` + Core `NBDStorageSpec`, `SignedRequestVerifier`, `P256Signer`/`P256KeyStore`, `WorkloadTokenIssuer` + `JSONVMIAMBindingStore` + HTTPAPIServer `/.well-known` OIDC-issuer endpoints (token-MINTING ≠ deleted token-VERIFYING), `UsedTicketCache`, `AdminPresenceGate` + break-glass host machinery + `Commands/BreakGlass.swift` (per-action MFA is a user requirement), `Commands/{RBAC,IAM,Identity,SignRequest,SecurityControls}.swift`, `AuditSink` protocol + `OSLogAuditSink` + `JSONFileAuditSink` + `DualAuditSink` + `AppendOnlyFileAuditStore` + `ImmutableAuditStore` protocol, `FleetSingleton` protocol + `InProcessFleetSingleton`, `FileDistributedLock`, `AgentEventListener`, `HostMetricsSampler`, `VirtualMachine.agentEventListener()`, Core `GuestEvent`/`AgentFrameCodec`/`SpiceStatusSnapshot`, `GuestAgentModels` DTOs `GuestStatsResponse`/`GuestPortInfo`/`GuestAppInfo`, `ClipboardStatusPill`, HTTPAPIServer (minus identityVerifier), `Serve.swift` (trimmed), OTLPExporter + `/metrics`.
- `Tests/SpooktacularKitTests/GuestToolsProvisioningGateTests.swift` greps `Sources/Spooktacular/AppState.swift` for the literal string `installsAppBundle` — do not rename that symbol or restructure `runMacOSCreate`'s provisioning gate.
- `SecurityControlInventoryTests` asserts every inventory `implementation` path and `test` file EXISTS ON DISK. Every file deletion must remove/repoint its `SecurityControlInventory.swift` entries in the same commit.
- `DocConsistencyTests` test 1 fails on any dangling `](Sources/...)` link in README — README link edits land in the same commit as the source deletion.
- No force-unwraps: when touching a file containing `!` on Optionals, fix them (user rule).
- Pre-1.0: no compat shims, no legacy fallbacks (user rule).
- Commit messages: conventional commits, end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Delete NetworkFilter system extension

**Files:**
- Delete: `Sources/SpooktacularNetworkFilter/` (main.swift), `Sources/SpooktacularInfrastructureApple/{SpooktacularNetworkFilterProvider,NEFilterConfigurator,FilterSettingsCompiler,SystemExtensionActivator,JSONTenantEgressPolicyStore}.swift`, `Sources/SpooktacularCore/TenantEgressPolicy.swift`, `Sources/SpooktacularApplication/TenantEgressPolicyStore.swift`, `Sources/spooktacular-cli/Commands/Egress.swift`, `Tests/SpooktacularKitTests/{SpooktacularNetworkFilterProviderTests,TenantEgressPolicyTests}.swift`, `SpooktacularNetworkFilter.entitlements`, `Resources/SpooktacularNetworkFilter-Info.plist`
- Modify: `Package.swift` (product ~line 34 + comment 29-33; target ~lines 123-135), `Sources/spooktacular-cli/Spooktacular.swift` (remove `Egress.self,`), `Sources/Spooktacular/SettingsView.swift` (tab registration ~14-15 + `NetworkFilterSettingsView` ~168-323; ALSO fix the force-unwrapped `URL(string:)!` at ~115-116 while touching this file), `Spooktacular.entitlements` (remove `com.apple.developer.networking.networkextension` key + Track F'' comment), `build-app.sh` (sysex sections), `scripts/find-provisioning-profile.sh:7` (usage-example comment)

**Interfaces:**
- Produces: a tree with zero references to `TenantEgressPolicy`, `NEFilterConfigurator`, `SystemExtensionActivator`, `spook egress`.

- [ ] **Step 1: build-app.sh — extract shared version vars FIRST.** `SYSEX_VERSION`/`SYSEX_BUILD` (~lines 144-145) are reused by the XPC helper (~169-170), notarization (~248), and Guest Tools stamping (~316-317). Rename them to `BUNDLE_VERSION`/`BUNDLE_BUILD` at definition and all use sites (`grep -n 'SYSEX_VERSION\|SYSEX_BUILD' build-app.sh`), moving the definition above the sysex block.
- [ ] **Step 2: build-app.sh — remove sysex sections.** Locate with `grep -n 'SYSEX\|SystemExtensions\|networkextension' build-app.sh`; remove: SYSEX_ID/TARGET (~29-33), SYSEX_DIR (~38-40), SYSEX_ENTITLEMENTS/INFO_PLIST (~61-62), `$SYSEX_MACOS` in mkdir (~111), the `.systemextension` assembly block (~126-147), profile gating (~364-453: PROFILE_HAS_SYSEX, entitlement-array filtering, both `rm -rf .../SystemExtensions`, sysex profile embed), dev-variant entitlement strip (~464-470), sysex codesign (~552-558). Run `bash -n build-app.sh` after.
- [ ] **Step 3: Delete files.** `git rm -r` everything in the Delete list above.
- [ ] **Step 4: Edit Package.swift.** Remove the `.executable(name: "SpooktacularNetworkFilter", ...)` product with its comment block and the `.executableTarget(name: "SpooktacularNetworkFilter", ...)` target with its comment.
- [ ] **Step 5: Remove inbound refs.** `grep -rn 'Egress\|TenantEgressPolicy\|NEFilterConfigurator\|SystemExtensionActivator\|NetworkFilter' Sources/ Tests/ *.entitlements scripts/ build-app.sh` — remove `Egress.self,` from `Spooktacular.swift`, the SettingsView tab + `NetworkFilterSettingsView` struct, the entitlements key, the script comment. While in SettingsView, replace `URL(string: "...")!` with a `guard let`-style fallback (e.g. computed property returning `URL?` consumed via `if let`).
- [ ] **Step 6: Verify.** `swift build && swift test --parallel --skip SpooktacularUITests` → both green; the final grep from Step 5 returns only unrelated matches (e.g. the word "filter" in Spotlight contexts).
- [ ] **Step 7: Commit.** `descope(netfilter): remove NEFilterDataProvider egress firewall (~1.7k LOC)`

### Task 2: Delete embedded MDM server

**Files:**
- Delete: `Sources/SpooktacularApplication/EmbeddedMDM/` (14 files), `Sources/SpooktacularInfrastructureApple/{EmbeddedMDMServer,MDMIdentityIssuer,MDMUserDataPkgBuilder}.swift`, `Sources/spooktacular-cli/Commands/MDM.swift`, all 17 MDM test files (`ls Tests/SpooktacularKitTests/ | grep -i mdm` + `DiskInjectorMDMTests.swift` + `SpooktacularMDMHandlerTests.swift`), `docs/MDM.md`
- Modify: `Sources/spooktacular-cli/Spooktacular.swift` (remove `MDM.self,`), `Sources/SpooktacularInfrastructureApple/DiskInjector.swift` (remove `injectMDMEnrollment` ~197-223 + doc mentions at ~19 and ~173), `README.md` (lines ~28 MDM blurb, ~141 EmbeddedMDM table row, ~164 `spook mdm` row), `docs/CODE_HYGIENE.md` (~185, ~210 MDM.md links), `Sources/SpooktacularKit/Documentation.docc/CLIReference.md` (~663 `spook mdm serve` example), `Tests/SpooktacularKitTests/DocConsistencyTests.swift` (~142-143 comment justifying `os` import via "embedded MDM's actors" — reword)

**Interfaces:**
- Produces: zero `MDM` symbols in Sources/Tests. (Package.swift needs NO edit — MDM has no target of its own.)

- [ ] **Step 1: Delete** all files in the Delete list (`git rm`).
- [ ] **Step 2: Edit inbound refs** per Modify list; relocate each with `grep -rn 'MDM' Sources/ Tests/ README.md docs/CODE_HYGIENE.md` (expect remaining hits only in files owned by later tasks: `AppleSSOProvider.swift` (Task 5), `SettingsView.swift`/`BundleProtectionTests.swift` comments — reword those two comments now). `IconSpec.swift:104` `"mdm"` preset string: remove the array entry (it has zero consumers).
- [ ] **Step 3: Verify.** `swift build && swift test --parallel --skip SpooktacularUITests` green; `swiftlint --strict --quiet | wc -l` drops by 8 (the MDM missing_docs/private_over_fileprivate/unused_closure_parameter errors die with the files).
- [ ] **Step 4: Commit.** `descope(mdm): remove embedded Apple MDM server (~4.4k src + 3.2k test LOC)`

### Task 3: Delete Kubernetes controller (+ KubernetesLeaseLock)

**Files:**
- Delete: `Sources/spooktacular-controller/` (8 files), `Tests/SpooktacularKitTests/K8sConditionMergerTests.swift`, `deploy/kubernetes/` (25 files), `docs/kubernetes.md`, `Sources/SpooktacularKit/Documentation.docc/KubernetesGuide.md`, `docs/observability/{grafana-dashboard-controller.json,grafana-dashboard-fleet.json,prometheus-scrape-config.yaml,slo-catalog.md}`, `Sources/SpooktacularInfrastructureApple/KubernetesLeaseLock.swift`
- Modify: `Package.swift` (remove `.executableTarget(name: "spooktacular-controller", ...)` ~202-206), `Tests/SpooktacularKitTests/DocConsistencyTests.swift` (delete test 6 "Helm TLS default matches NodeManager default scheme", ~299-348), `Sources/SpooktacularInfrastructureApple/DistributedLockFactory.swift` (remove K8s branch ~90-97 + doc ~20-23 + `Backend` case), `Sources/spooktacular-cli/Commands/Serve.swift` (~201 comment, ~207 `k8sSelected`, ~210 condition), `Sources/spooktacular-cli/Commands/Doctor.swift` (~482-485 K8s-lock check), `Sources/SpooktacularApplication/ProductionPreflight.swift` (~144,157 `SPOOK_K8S_API` strings), `Sources/SpooktacularKit/SecurityControlInventory.swift` (entry ~292 "Cross-region distributed lock" if it cites KubernetesLeaseLock — verify with grep; also reword controller-claim strings at ~155,163,246,297,324), docc cross-refs `grep -rln '<doc:KubernetesGuide>' Sources/SpooktacularKit/Documentation.docc/` (9 files), `docs/observability/{alerts.yml,README.md}` (controller blocks: alerts ~169,241,280-291; README ~14,17,38), `README.md` (~138 Kubernetes row + ~206-226 "Runner Pools (Kubernetes)" section), `CONTRIBUTING.md` (~73), `CODEOWNERS` (~45,47 stale `Sources/spook-controller/`), `SECURITY.md` (~38, ~266 controller lines), `Sources/SpooktacularKit/SpooktacularKit.swift` (~4 comment), `Sources/SpooktacularCore/TLSIdentityProvider.swift` (~16 doc), `Sources/SpooktacularCore/FairScheduler.swift` (~76 doc), `Sources/SpooktacularCore/DistributedLock.swift` (~6 ``KubernetesLeaseLock`` doc link), `deploy/ec2-mac/` mentions (README.md ~287, bootstrap.sh ~84,479, terraform/outputs.tf ~31, terraform/main.tf ~91 — reword to spook-serve-only), `Tests/SpooktacularKitTests/FairSchedulerTests.swift` (~7,220 comments)

**Interfaces:**
- Consumes: nothing. Produces: `RunnerPoolManager`/`FairScheduler`/`WorkflowJobWebhook`/`KeychainTLSProvider` become production-orphaned — that is EXPECTED; they are salvage inputs to the runner-e2e plan. Do not delete them.

- [ ] **Step 1: Delete** files (`git rm -r`); remove the Package.swift target block in the SAME change (orphaned path or orphaned target each break `swift build`).
- [ ] **Step 2: Remove DocConsistencyTests test 6** (it `readProjectFile`s `deploy/kubernetes/helm/...` and `Sources/spooktacular-controller/NodeManager.swift` at RUNTIME — compiles but fails if left).
- [ ] **Step 3: Edit remaining refs** per Modify list; relocate each via `grep -rn 'spooktacular-controller\|spook-controller\|KubernetesGuide\|KubernetesLeaseLock\|SPOOK_K8S_API\|RunnerPoolReconciler\|NodeManager\|MacOSVM' Sources/ Tests/ docs/ deploy/ README.md CONTRIBUTING.md CODEOWNERS SECURITY.md`.
- [ ] **Step 4: Verify.** Build + full test green. Re-run the Step 3 grep → no hits outside `plans/` and CHANGELOG history prose.
- [ ] **Step 5: Commit.** `descope(k8s): remove Kubernetes operator, CRDs, Helm chart, K8s lease lock (~8k LOC)`

### Task 4: Delete orphaned guest-agent RPC stack (host + library)

**Files:**
- Delete: `Sources/SpooktacularGuestAgentCore/` (13 files, 3,684 LOC), `Sources/SpooktacularInfrastructureApple/{GuestAgentClient,PortForwarder,VsockProvisioner}.swift`, `Sources/spooktacular-cli/Commands/{Remote,Forward}.swift`, `Sources/SpooktacularCore/{TunnelPath,GuestAgentError}.swift`, `Sources/Spooktacular/HostIntegration/ClipboardBridge.swift`, `Sources/Spooktacular/PortForwarding.swift`, `Examples/GuestAgentRPC/`, Tests: `{GuestAgentServerAuthPolicyTests,AgentHTTPServerLaunchResilienceTests,TunnelHandlerTests,WorkloadTokenRefresherTests,VsockProvisionerTests,GuestAgentClientIsolationTests}.swift`
- Modify: `Package.swift` (GuestAgentCore target ~148-165, test-dep line ~237 + comment ~230-236, Examples target ~218-222), `Sources/spooktacular-cli/Spooktacular.swift` (remove `Remote.self,` and `Forward.self,`), `Sources/spooktacular-cli/Commands/Start.swift` (`.agent` branch ~292-322), `Sources/spooktacular-cli/Commands/Create.swift` (~559 `.agent` case-list mention), `Sources/SpooktacularCore/ProvisioningMode.swift` (remove `case agent` at ~71 + switches ~96,108,127), `Sources/SpooktacularInfrastructureApple/VirtualMachine.swift` (remove `makeGuestAgentClient` ~263-293 + doc refs ~114,~308,~438), `Sources/Spooktacular/AppState.swift` (remove `agentClients` ~153, creation ~580-582, removals ~834,~903,~1301,~1598, portMonitor wiring ~243-245, `portMonitors`/`portMonitor(for:)` ~189,~237-247, ClipboardBridge property ~224), `Sources/Spooktacular/Views/WorkspaceStatsSidebar.swift` (`start(listener:client:)`→`start(listener:)` ~100; delete hostProbeTask ~81,104-109, probeHostMetrics ~202-215, lastLatencyMs/lastPortCount ~86-87, Sample.portCount/.latencyMs ~35-36), `Sources/Spooktacular/VMDetailView.swift` (simplify `.task` ~31-44, drop `agentClients[name]` requirement), `Sources/Spooktacular/Windows/WorkspaceWindow.swift` (remove Ports toolbar button + popover ~158-168 + showPorts state; ClipboardStatusPill STAYS), `Sources/Spooktacular/Intents/IntentAppState.swift` (remove `runCommand` ~117-133 + `IntentError.noGuestAgent`), `Sources/Spooktacular/Intents/VMIntents.swift` (remove `RunCommandInVMIntent` ~174-196), `Sources/SpooktacularCore/GuestAgentModels.swift` (delete DTOs `GuestHealthResponse,GuestExecResponse,GuestFSEntry,GuestFileInfo,GuestExecRequest,GuestClipboardContent,GuestAppRequest,GuestFilePayload`; KEEP `GuestStatsResponse,GuestPortInfo,GuestAppInfo`), `Tests/SpooktacularKitTests/GuestAgentTests.swift` (trim deleted-DTO round-trips ~13-70 + GuestAgentErrorTests ~77-120; keep GuestAppInfo/GuestPortInfo), `Sources/SpooktacularKit/SecurityControlInventory.swift` (delete entries at ~104,136,174,182,244,314 — every entry citing `SpooktacularGuestAgentCore/` or `GuestAgentClient.swift`), `README.md` (~131 GuestAgentCore link row, ~183-204 Guest Agent section)

**Interfaces:**
- Produces: stats/clipboard/events pipeline still works: `HostMetricsSampler → AgentEventListener.inject() → WorkspaceStatsModel / UDS republisher / clipboardStatuses`. `SignedRequestVerifier` untouched.

- [ ] **Step 0: Persisted-enum safety check.** `grep -l '"agent"' ~/.spooktacular/vms/*/metadata.json ~/.spooktacular/vms/*/config.json 2>/dev/null` — expect empty (pre-1.0 rule: no decode shim; if a hit appears, note the bundle and proceed — stale local bundle, not shipped data).
- [ ] **Step 1: Delete + Package.swift edits** (target, test-dep, Examples target) atomically.
- [ ] **Step 2: Apply Modify list.** Relocate every edit via `grep -rn 'GuestAgentClient\|GuestAgentCore\|makeGuestAgentClient\|agentClients\|portMonitor\|ClipboardBridge\|RunCommandInVMIntent\|TunnelPath\|VsockProvisioner\|ProvisioningMode.agent\|case agent' Sources/ Tests/`. Do NOT touch `installsAppBundle` or the `runMacOSCreate` provisioning gate.
- [ ] **Step 3: Verify.** Build + full test green (watch for RUNTIME failures, not just compile: the resilience test reads a deleted path via `#filePath` — it must be gone). GUI smoke: `swift build` includes the Spooktacular target; confirm no `Remote`/`Forward` in `spook --help` output (`.build/debug/spooktacular-cli --help` or the built `spook`).
- [ ] **Step 4: Commit.** `descope(guest-rpc): remove orphaned guest-agent library + dead host RPC surface (~6.5k LOC)`

### Task 5: Delete SAML/OIDC identity-verification stack

**Files:**
- Delete: `Sources/SpooktacularInfrastructureApple/{XMLCanonicalization,SAMLAssertionVerifier,OIDCTokenVerifier,MultiIdPVerifier,AppleSSOProvider}.swift`, `Sources/SpooktacularApplication/FederatedAuthService.swift`, `Sources/SpooktacularCore/{FederatedIdentity,SAMLAssertion}.swift`, Tests: `{SAMLSignatureTests,SAMLVerifierTests,XMLCanonicalizationTests,OIDCHardeningTests,OIDCACRTests,FederatedIdentityTests}.swift`, `docs/guides/` (all 6 SSO guides)
- Modify: `Sources/SpooktacularInfrastructureApple/HTTPAPIServer.swift` (remove `identityVerifier` property ~253-256, init param ~317, assignment ~350, JWT branch + `looksLikeJWT` ~1055-1100 — KEEP SignedRequestVerifier path ~1101+ and `/.well-known` issuer endpoints ~1042-1051), `Sources/spooktacular-cli/Commands/Serve.swift` (remove print-only IdP block ~188-195), `Sources/SpooktacularApplication/RBACService.swift` (remove `IdPConfig` ~183-220; KEEP `ImmutableAuditStore` ~230-240), `Sources/SpooktacularApplication/SpooktacularConfig.swift` (remove `IdentityProviderConfig` + `identityProviders` ~35,56,262), `Sources/spooktacular-cli/Commands/Doctor.swift` (remove IdP checks 8 ~380-408 and 19 ~546-580), `Tests/SpooktacularKitTests/CryptoHardeningTests.swift` (delete suites at ~19,45,118,138,163; KEEP "HMAC empty secret defense" ~185 and "BreakGlass clock-skew" ~221), `Sources/SpooktacularKit/SecurityControlInventory.swift` (delete entries ~69,77,85,117), `Tests/SpooktacularKitTests/DoctorStrictChecksTests.swift` (drop removed-check assertions — grep for check numbers)

**Interfaces:**
- Consumes: Task 3 must land first (the controller was the only `MultiIdPVerifier` constructor). Produces: HTTPAPIServer auth = signed requests only.

- [ ] **Step 1: HTTPAPIServer + Serve trims** (grep `identityVerifier\|looksLikeJWT\|FederatedIdentityVerifier\|SPOOKTACULAR_IDP_CONFIG`).
- [ ] **Step 2: Delete verifier files + FederatedAuthService.**
- [ ] **Step 3: Atomic model removal:** Core `FederatedIdentity.swift` + `SAMLAssertion.swift` + `RBACService.IdPConfig` + `SpooktacularConfig.IdentityProviderConfig` in one change (IdPConfig references both Core config types).
- [ ] **Step 4: Tests + inventory + Doctor + guides** per Modify list.
- [ ] **Step 5: Verify.** Build + test green. `grep -rn 'SAML\|OIDC' Sources/` → remaining hits only in WorkloadTokenIssuer/issuer-endpoint context (minting, kept) — read each hit to confirm.
- [ ] **Step 6: Commit.** `descope(idp): remove SAML/OIDC verification stack incl. hand-rolled XML c14n (~3.3k LOC)`

### Task 6: Delete hand-rolled AWS clients + trim audit stores

**Files:**
- Delete: `Sources/spooktacular-cli/Commands/{EBS,Audit,Incident}.swift`, `Sources/SpooktacularInfrastructureApple/{EBSNBDServer,EBSDirectClient,KeychainCredentialProvider,SigV4RequestSigner,SigV4Signer,HTTPSClient,DynamoDBDistributedLock,DynamoDBFleetSingleton,S3ObjectLockAuditStore,WebhookAuditSink,HashChainAuditSink,AuditSinkFactory}.swift`, `Sources/SpooktacularApplication/MerkleTreeVerifier.swift`, Tests: `{EBSDirectClientTests,HTTPSClientTests,DynamoDBDistributedLockTests,MerkleTreeVerifierTests,SpookAuditVerifyTests,S3AuditStoreTests,WebhookAuditSinkTests,EnterpriseReadinessTests}.swift` (verify each file's actual coverage before deleting; trim instead if it also covers kept code)
- Create: `Sources/SpooktacularInfrastructureApple/InProcessFleetSingleton.swift` (move `InProcessFleetSingleton` out of `DynamoDBFleetSingleton.swift` BEFORE deleting that file — it is the only remaining `FleetSingleton` impl and tests + `SignedRequestVerifier`/`UsedTicketCache` consumers need the protocol chain intact)
- Modify: `Sources/spooktacular-cli/Spooktacular.swift` (remove `EBS.self,`, `SpooktacularAudit.self,`, `Incident.self,`), `Sources/SpooktacularInfrastructureApple/DistributedLockFactory.swift` (trim to file-lock only; remove Dynamo tier ~84-90 and remaining `Backend` cases), `Sources/spooktacular-cli/Commands/Serve.swift` (~197-224 backend selection trim; ~239-265 Merkle block removal — keep the JSONFile+AppendOnly+Dual chain ~226-238), `Sources/spooktacular-cli/Commands/Doctor.swift` (remove checks 11/12/13 ~448-480), `Sources/SpooktacularApplication/SpooktacularConfig.swift` (remove merkle/s3/webhook AuditConfig fields ~307+; note `SPOOK_AUDIT_S3_BUCKET` at ~126 dies here — the last SPOOK_-prefixed env read), `Sources/spooktacular-cli/Commands/Identity.swift` (remove `audit-key` subcommand if it only feeds Merkle signing — grep first), `Sources/SpooktacularKit/SecurityControlInventory.swift` (delete entries ~190,206,257,273,292), `Sources/SpooktacularCore/AuditSink.swift` (fix doc ~22,32-33 naming deleted sinks), `Sources/SpooktacularCore/FleetSingleton.swift` (~30 doc), `Sources/SpooktacularCore/DistributedLock.swift` (~6-7 doc), `Sources/SpooktacularApplication/UsedTicketCache.swift` (~169 doc), `Sources/SpooktacularInfrastructureApple/AdminPresenceGate.swift` (~356 error string names S3/HashChain), `Sources/SpooktacularInfrastructureApple/HMACRequestSigner.swift` (~7 doc), `Tests/SpooktacularKitTests/AuditPipelineTests.swift` (delete Merkle suites ~26-127; keep AppendOnly ~136-159, DualAuditSink ~192-217), `Tests/SpooktacularKitTests/EnterpriseIntegrationTests.swift` (delete Merkle suite ~72-110; keep tenancy ~11-70), `Tests/SpooktacularKitTests/DoctorStrictChecksTests.swift` (sync)

**Interfaces:**
- Consumes: Task 3 (controller was a MerkleAuditSink/AuditSinkFactory consumer). Produces: audit = OSLog + JSONFile + AppendOnly + Dual only; locks = file-only; `ProductionPreflight.hasAuditSink` still satisfiable (JSONFile chain in Serve survives).

- [ ] **Step 1: Move `InProcessFleetSingleton`** to its own file; build.
- [ ] **Step 2: CLI deletions + registrations** (EBS, Audit, Incident).
- [ ] **Step 3: Delete AWS client chain** in consumer order: EBSNBDServer → EBSDirectClient → KeychainCredentialProvider → SigV4RequestSigner → HTTPSClient → (locks) DynamoDBDistributedLock + DynamoDBFleetSingleton → (audit) S3ObjectLockAuditStore → SigV4Signer → WebhookAuditSink → HashChainAuditSink → MerkleTreeVerifier → AuditSinkFactory. KEEP `NBDAttachmentMonitor` + Core `NBDStorageSpec` (generic VZ NBD disk support — verify with `grep -rn NBDAttachmentMonitor Sources/`).
- [ ] **Step 4: Apply trims** per Modify list (grep-first for every cited line).
- [ ] **Step 5: Verify.** Build + full test green; `spook serve` default secure mode still boots in a smoke check: `SPOOKTACULAR_… .build/debug/spooktacular-cli serve --help` at minimum, plus `ProductionPreflightTests` green.
- [ ] **Step 6: Commit.** `descope(aws): remove hand-rolled AWS clients, Merkle/S3/webhook audit, Dynamo locks (~4.5k LOC)`

### Task 7: Fiction-docs purge + root-file trims

**Files:**
- Delete: `docs/{AUDIT_STATUS,DATA_PROCESSING_AGREEMENT,SUB_PROCESSORS,EXPORT_CONTROL,PATCH_POLICY,VPAT,DISASTER_RECOVERY,INCIDENT_RESPONSE,THREAT_MODEL,OWASP_ASVS_AUDIT}.md`, `docs/superpowers/` (all 4 roleplay artifacts — currently PUBLISHED at spooktacular.app/superpowers/)
- Modify: `SECURITY.md` (trim to ~90 lines: keep Supported Versions, Reporting, Contact/PGP, Scope minus controller line; delete Security Model/Deployment Models/Security Operations/Architectural Invariants ~13-197,276-287), `CODEOWNERS` (trim to `* @WikipediaBrown` + surviving real paths only), `CONTRIBUTING.md` (remove controller architecture line ~73, "K8s controller are thin clients", reconsider GPG-required claim), `CHANGELOG.md` (rewrite `[Unreleased]` honestly: checkpoint + descope summary; file must STAY — Dangerfile keys on it), `CITATION.cff` (drop `kubernetes` keyword), `docs/DEPLOYMENT_HARDENING.md` (rewrite item list to match post-descope `spook doctor --strict` output — run the built `spook doctor --strict` and mirror it 1:1; Doctor.swift ~21,25,59,70,138,160 claims the doc maps 1:1), `docs/EC2_MAC_DEPLOYMENT.md` (trim IAM/DynamoDB/S3/K8s content to install/run/doctor reality), `docs/observability/README.md` + `alerts.yml` (host-level only; verify remaining metric names against `Sources/SpooktacularApplication/OTLPExporter.swift` and Metrics.swift), `docs/CODE_HYGIENE.md` (~190 env-rename row check), code comments citing THREAT_MODEL (`SpooktacularConfig.swift:325`, `Serve.swift:246`, `GitHubTokenResolutionTests.swift`), `README.md` (~265 remove `137 pass / 0 fail` + doc links to deleted files; ~285 `#structured-audit-logging` anchor fix), `docs/{index,features,compare,roadmap}.html` (content-truth pass: index ~424 RunnerPool CRD/webhooks; features MDM/K8s/SAML claims ×4; compare ×3 incl. ~503 branch mention; roadmap ×1)
- Keep untouched: `docs/{versioning.md,CODE_HYGIENE.md core,GUEST_TOOLS_E2E_VERIFICATION.md,DATA_AT_REST.md}` (GUI links DATA_AT_REST at runtime), `docs/api/` (site nav + README:18 + SUPPORT.md depend on it; regenerating DocC is out of scope), `SUPPORT.md`, `Dangerfile`, `docs/observability/{metrics.md,prometheus.yml,grafana-dashboard.json}` (verify + keep)

- [ ] **Step 1: Delete** the fiction cluster (`git rm`).
- [ ] **Step 2: Trims** per Modify list. For DEPLOYMENT_HARDENING: run `.build/debug/spooktacular-cli doctor --strict` (or the `spook` binary) and rewrite the doc's item list to exactly the surviving checks.
- [ ] **Step 3: Link integrity.** `grep -rn 'THREAT_MODEL\|OWASP_ASVS\|AUDIT_STATUS\|SUB_PROCESSORS\|DATA_PROCESSING\|EXPORT_CONTROL\|PATCH_POLICY\|VPAT\|DISASTER_RECOVERY\|INCIDENT_RESPONSE\|superpowers' README.md SECURITY.md docs/ Sources/ Tests/ deploy/ scripts/` → zero hits outside `plans/` and CHANGELOG history.
- [ ] **Step 4: Verify.** Build + full test green (DocConsistency link tests pass).
- [ ] **Step 5: Commit.** `docs(descope): purge compliance fiction; trim SECURITY/CODEOWNERS/hardening docs to reality`

### Task 8: README truth pass + final lint + CI-blocker fixes

**Files:**
- Modify: `README.md`, `Sources/SpooktacularCore/SpiceStatusSnapshot.swift`, `build-app.sh`, `.github/workflows/ci.yml` (header comment only)

- [ ] **Step 1: SwiftLint zero.** Fix `SpiceStatusSnapshot.swift:23` → `case notStarted = "notStarted"` (preserves documented wire format). (`Remote.swift:51` died in Task 4.) Run `swiftlint --strict --quiet` → exit 0, zero output. If new violations surfaced in surviving files during Tasks 1-7, fix them now (missing_docs → write real DocC comments).
- [ ] **Step 2: build-app.sh CI signing fallback.** Restore ad-hoc default so GitHub-hosted runners can build: locate the identity resolution (~520-532, `grep -n 'CODESIGN_IDENTITY\|No code-signing identity' build-app.sh`) and change the hard `exit 1` path to default `SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"` (ad-hoc `-`), keeping the Apple-Development auto-detect when present (matches main's behavior at its line 85). Verify `CODESIGN_IDENTITY= ./build-app.sh release` completes locally.
- [ ] **Step 3: README full edit** per scouted list: line ~12 remove CodeQL badge (no codeql.yml); ~294 remove CodeQL claim; ~312 remove Docs-workflow row (no docs.yml); ~309 CI table → actual ci.yml jobs (lint, test+build+validate, xcode compile-check — no DocC, no UI-test run); ~324 PR-template link case → `.github/pull_request_template.md`; ~70 brew cask → replace with real install path (build-app.sh / releases when they exist — no fictional cask); ~79-85 quick start → real interface:
  ```bash
  spook create runner-01 --github-runner --github-repo org/repo --github-token-keychain <account>
  ```
  ~47 command count → recount `grep -c '\.self,' Sources/spooktacular-cli/Spooktacular.swift`; ~90-119 architecture diagram → correct module names (SpooktacularCore/Application/InfrastructureApple), drop controller box; ~35-38 comparison table → drop deleted-feature claims; ~228-251 EC2 section → keep but strip SSM/controller fiction; ~253-285 Security/Audit sections → surviving controls only, fix `SPOOK_AUDIT_FILE` → `SPOOKTACULAR_AUDIT_FILE` (verify actual env name in code first).
- [ ] **Step 4: Test-count sync.** `swift test --parallel --skip SpooktacularUITests 2>&1 | grep 'Test run with'` → take N; update README badge line ~16 `Tests-N_passing`, ~301 `# Run N tests`, ~323 `(N tests)`. Run `scripts/ci/validate-readme-claims.sh <test-output-file>` locally → exit 0.
- [ ] **Step 5: Verify all gates locally.** `swiftlint --strict --quiet` (exit 0) && `swift build -c release` && full `swift test` && `./build-app.sh release` && `bash -n build-app.sh`.
- [ ] **Step 6: Commit.** `fix(ci): zero lint, ad-hoc signing fallback, README truth pass + count sync`

### Task 9: Push + CI green + guard

- [ ] **Step 1:** `git push origin feat/gui-rewrite-v2`.
- [ ] **Step 2:** `gh run watch` the PR #48 run (`gh run list --branch feat/gui-rewrite-v2 --limit 1`). Triggers are pull_request→main, so the push starts a run on the open PR.
- [ ] **Step 3:** If a job fails: read the log (`gh run view <id> --log-failed`), fix, commit, push, repeat. Known residual risks: xcodebuild scheme job (untested locally — if the scheme references deleted targets, regenerate via `project.yml`/xcodegen or fix scheme), Danger `pr_review` step (PR-event only; needs DANGER token from GITHUB_TOKEN — should pass), fastlane `lint_metadata`.
- [ ] **Step 4:** All jobs green → update task list; do NOT merge yet (runner-e2e plan lands on this branch first).
