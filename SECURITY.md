# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| latest  | Yes       |

We support the latest release only. Please update to the latest version before reporting a vulnerability.

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
- The `spook-agent` guest agent
- The `spook-controller` Kubernetes controller
- The HTTP API server (`spook serve`)
- The website at spooktacular.app

### Out of scope

- Apple Virtualization.framework bugs (report to Apple)
- macOS kernel vulnerabilities (report to Apple)
- Denial of service via resource exhaustion (2-VM limit is kernel-enforced)

## Security Design

- **HTTP API authentication**: Bearer token via `SPOOK_API_TOKEN` environment variable
- **VM name validation**: Regex-validated to prevent path traversal
- **Kubernetes TLS**: Cluster CA certificate verified via SecTrust
- **Guest agent**: Verifies host CID on vsock connections
- **Code signing**: Hardened runtime, notarized for distribution
- **No telemetry**: Zero data collection, no network calls to our servers
