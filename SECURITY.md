# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| latest  | Yes       |

We support the latest release only. Please update to the latest version before reporting a vulnerability.

## Security Model

Spooktacular is a **single-tenant, single-host** macOS VM manager designed for teams that own their Mac hardware. The security model is designed for trusted networks where the operator controls both the host and the guests.

### What this security model covers

- **Host ↔ Guest isolation**: VMs run in Apple's Virtualization.framework sandbox. The guest agent authenticates via bearer tokens over vsock (not over the network).
- **Host CID gating**: The guest agent verifies the vsock connection originates from the host (CID 2), rejecting peer-to-peer connections.
- **API authentication**: The HTTP API requires a bearer token (`SPOOK_API_TOKEN`) when not in `--insecure` mode. TLS is supported via `--tls-cert`/`--tls-key`.
- **Scope-based agent authorization**: The guest agent supports two token tiers — full-access (read + mutation) and read-only (health, list, inspect). Read-only tokens cannot execute commands, write files, or control applications.
- **Audit logging**: Every guest agent request is logged at `os.Logger` `.notice` level with method, path, status code, and ISO-8601 timestamp. Logs are queryable via Console.app or `log show`.
- **VM name validation**: Regex-validated to prevent path traversal.
- **Capacity enforcement**: 2-VM limit with flock-serialized PID file writes to prevent TOCTOU races.
- **Code signing**: Hardened runtime, notarized for distribution, no `--deep` signing.
- **No telemetry**: Zero data collection, no network calls to our servers.

### What this security model does NOT cover

These are **known limitations**, not bugs:

- **No mTLS**: The HTTP API uses server-side TLS only. There is no client certificate verification. The API relies on bearer tokens for authentication.
- **No per-user identity**: Authentication is token-based, not user-based. A single shared token authenticates all requests. There is no RBAC beyond the two-tier agent scope system.
- **No distributed locking**: Capacity enforcement uses `flock(2)`, which is per-host only. In a multi-controller deployment, each controller must target distinct hosts.
- **No tamper-resistant audit**: Audit logs use `os.Logger`, which is the standard macOS logging facility. Logs are not cryptographically signed or forwarded to a SIEM. Operators should configure log forwarding separately.
- **No cert rotation**: TLS certificates are loaded at startup. Rotation requires a server restart.
- **Blast radius of a compromised token**: A full-access API token grants control over all VMs on that host. A full-access agent token grants shell execution, file writes, and app control inside that guest. Use read-only tokens where mutation is not needed.

### Who should use Spooktacular

- DevOps teams running CI/CD on Mac hardware they own
- Teams that need remote desktops or code signing on dedicated Macs
- Operators comfortable with single-tenant security (one team per host)

### Who should NOT use Spooktacular (yet)

- Multi-tenant environments where untrusted users share the same host
- Environments requiring SOC 2 Type II compliance for the VM management layer
- Deployments requiring per-user RBAC, client certificate auth, or federated identity

## Reporting a Vulnerability

**Do not open a public issue for security vulnerabilities.**

Instead, please report vulnerabilities privately via one of these channels:

1. **GitHub Security Advisories** (preferred): [Report a vulnerability](https://github.com/Spooky-Labs/spooktacular/security/advisories/new)
2. **Email**: davisperris@gmail.com

### What to include

- Description of the vulnerability
- Steps to reproduce
- Affected version(s)
- Potential impact

### Response timeline

- **Acknowledgment**: Within 48 hours
- **Initial assessment**: Within 1 week
- **Fix release**: Within 2 weeks for critical issues

### Scope

The following are in scope for security reports:

- The `spook` CLI tool
- The `Spooktacular` GUI app
- The `spooktacular-agent` guest agent
- The `spook-controller` Kubernetes controller
- The HTTP API server (`spook serve`)
- The website at spooktacular.app

### Out of scope

- Apple Virtualization.framework bugs (report to Apple)
- macOS kernel vulnerabilities (report to Apple)
- Denial of service via resource exhaustion (2-VM limit is kernel-enforced)
