# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| N (current) | Yes   |
| N-1         | Yes   |
| < N-1       | No    |

We support the current release and the immediately prior release (N and N-1). Older versions do not receive security patches. Please update to a supported version before reporting a vulnerability.

## Reporting a Vulnerability

**Do not open a public issue for security vulnerabilities.**

Instead, please report vulnerabilities privately via one of these channels:

1. **GitHub Security Advisories** (preferred): [Report a vulnerability](https://github.com/Spooky-Labs/spooktacular/security/advisories/new)
2. **Email**: security@spooktacular.app

### What to include

- Description of the vulnerability
- Steps to reproduce
- Affected version(s)
- Potential impact

### Response timeline

- **Acknowledgment**: Within 48 hours
- **Initial assessment**: Within 1 week
- **Fix release**: Within 2 weeks for critical issues

## Security Contact — Encrypted Disclosure

For confidential vulnerability reports, encrypt to:

- **Email:** security@spooktacular.app
- **PGP key fingerprint:** `<PLACEHOLDER — operator must publish real key to https://keys.openpgp.org/search?q=security@spooktacular.app>`

The fingerprint above is a placeholder. The repo owner must generate a real key and replace this line before 1.0. Until a real key is published here, reporters who require encryption should file a GitHub Security Advisory draft (which is encrypted at rest by GitHub) rather than emailing ciphertext to an unpublished key.

Steps for the operator to publish before 1.0:

1. Generate a key on a trusted workstation:
   ```bash
   gpg --full-generate-key
   # Select: ECC (sign+cert), curve 25519, 0 (no expiry or 2y).
   # Real name: Spooktacular Security
   # Email:     security@spooktacular.app
   # Passphrase: strong; stored in a hardware-backed secret manager.
   ```
2. Add an encryption subkey:
   ```bash
   gpg --expert --edit-key security@spooktacular.app
   # > addkey  → (12) ECC (encrypt only) → curve 25519 → save
   ```
3. Export and publish:
   ```bash
   gpg --armor --export security@spooktacular.app > security.asc
   curl -T security.asc https://keys.openpgp.org/
   # Follow the verification email sent to security@spooktacular.app.
   ```
4. Capture the primary-key fingerprint:
   ```bash
   gpg --fingerprint security@spooktacular.app
   ```
5. Replace the placeholder above with the 40-hex-character fingerprint, in the canonical 10-group-of-4 format.
6. Commit the change in a signed commit and announce the fingerprint in the next release notes and on any social channels operated by Spooky Labs, so reporters can cross-check before encrypting.
7. Add the fingerprint to the `Cache-Control: immutable` `security.txt` published at `https://spooktacular.app/.well-known/security.txt` per RFC 9116.

### Scope

The following are in scope for security reports:

- The `spook` CLI tool
- The `Spooktacular` GUI app
- The `Spooktacular Guest Tools.app` in-guest companion (SPICE clipboard bridge)
- The HTTP API server (`spook serve`)
- The website at spooktacular.app

### Out of scope

- Apple Virtualization.framework bugs (report to Apple)
- macOS kernel vulnerabilities (report to Apple)
- Denial of service via resource exhaustion (2-VM limit is kernel-enforced)
