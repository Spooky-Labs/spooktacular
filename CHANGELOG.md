# Changelog

All notable changes to Spooktacular are documented here.

This project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Rich guest agent with 12 HTTP endpoints (clipboard, exec, apps, files, ports, health)
- `spook remote` CLI command for guest agent interaction
- GuestAgentClient actor for host-side guest API
- KeyboardDriver protocol (SpooktacularKit no longer imports AppKit)
- MACAddress value type with validation and Codable support
- ProcessRunner shared async-safe process execution
- NetworkMode proper Codable with backward-compatible decoder
- HTTP API Bearer token authentication (`SPOOK_API_TOKEN`)
- VM name validation (path traversal protection)
- Kubernetes leader election via Lease API
- Kubernetes finalizers for resource cleanup
- Atomic snapshot restore via temp file + replaceItem
- machine-identifier.bin included in snapshots
- Graceful stop with 30s timeout then force-stop escalation
- VirtualMachine.lastError for surfacing VZ errors
- Network disconnect delegate implementation
- Separate SpookCLI.entitlements (no app-sandbox for CLI)
- Liquid Glass UI across entire GUI (macOS 26+)
- RunnerPool reconciliation with lifecycle state machine (9 states: idle, provisioning, registering, ready, busy, completing, recycling, draining, terminated)
- GitHub webhook integration (HMAC-SHA256 verified `workflow_job` events for real-time job detection)
- Three-tier pool recycling strategies (reclone: fresh APFS clone, snapshot: restore to clean snapshot, scrub: in-place cleanup)
- Clean Architecture restructure (Entities / UseCases / Interfaces / Infrastructure layers)
- mTLS support for controller-to-node traffic (optional, enabled via `--mtls-ca`)
- Keychain-based secret storage (API tokens and TLS keys stored in macOS Keychain)
- Three-tier guest agent authorization (read-only, runner, break-glass token scopes)
- TLS certificate hot reload (zero-downtime cert rotation via file watching)
- OSSignposter lifecycle tracing (structured os_signpost intervals for VM and runner lifecycle)
- CodeQL static analysis, SBOM generation, and artifact attestations in CI
- EC2 Mac enterprise mode (Host Resource Group placement, drain procedures, IMDS identity verification)
- Automated doc consistency test suite (verifies docs match code for test counts, feature claims, and API surface)

### Fixed
- Notarization uses `xcrun notarytool` (Fastlane wrapper broken)
- `launchctl bootstrap/bootout` replaces deprecated `load/unload`
- `systemsetup -setremotelogin` replaced with `launchctl bootstrap`
- DiskInjector defer moved before throw point
- VsockProvisioner read is async (no main thread blocking)
- SSHExecutor uses terminationHandler (no thread pool blocking)
- Stale PID files proactively cleaned during capacity scan
- IPSW cache integrity check (zero-byte files re-downloaded)
- Ephemeral cleanup requires stale PID (not missing PID)
- Stop timeout exits non-zero
- Delete --force verifies kill succeeded
- ServicePlist XML-escapes all interpolated values
- Guest agent verifies host CID on vsock connections
- GitHub runner template uses JSON parsing (not grep)
- Codesign: inner-first order, hardened runtime, no --deep
- Version injected from git tag into Info.plist

### Changed
- CI triggers on PRs only; Beta triggers on merge to main
- Release workflow notarizes and staples before publishing
- HTTPAPIServer split into HTTPRequest, HTTPResponse, APIModels
- 411+ tests in 50+ suites (was 297 in 36)

## [0.1.0] - 2026-04-13

### Added
- Initial release
- VM creation from IPSW restore images
- APFS copy-on-write cloning (48ms)
- Full VM lifecycle (start/stop/pause/resume/save/restore)
- Unattended Setup Assistant automation (macOS 15 + 26)
- SSH provisioning with streaming output
- Disk-inject provisioning (zero-network LaunchDaemon)
- VirtIO socket provisioning with guest agent
- GitHub Actions runner, remote desktop, OpenClaw templates
- Ephemeral runners (auto-destroy on stop)
- Disk-level snapshots (save/restore/list/delete)
- 2-VM capacity enforcement
- HTTP REST API (9 endpoints)
- Kubernetes operator (MacOSVM CRD, Swift controller, Helm chart)
- 14 CLI commands
- SwiftUI GUI with Liquid Glass
- Menu bar extra
- Full VoiceOver accessibility
- NAT, bridged, isolated networking
- Metal GPU displays, audio, shared folders
- Per-VM LaunchDaemon services

[Unreleased]: https://github.com/Spooky-Labs/spooktacular/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Spooky-Labs/spooktacular/releases/tag/v0.1.0
