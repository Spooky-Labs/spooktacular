# Patch and Vulnerability Management Policy

**Status:** Living document — updated per release.
**Owner:** security@spooktacular.app
**Audience:** operators running Spooktacular in production; procurement reviewers asking about patch cadence.

Spooktacular ships security fixes on a published timeline. This page is the ground truth; marketing or sales statements that contradict it should be treated as outdated.

## 1. Vulnerability sources

Spooky Labs monitors:

- **Dependabot** — enabled on the GitHub repository for every Package.resolved update. Alerts are routed to the maintainer via GitHub's Security tab.
- **NVD (National Vulnerability Database)** — <https://nvd.nist.gov/>. Weekly triage on every CVE that affects a dependency (note: Spooktacular has zero third-party runtime dependencies; Apple SDKs only — see [`THREAT_MODEL.md`](THREAT_MODEL.md) §5).
- **CISA Known Exploited Vulnerabilities (KEV) catalog** — <https://www.cisa.gov/known-exploited-vulnerabilities-catalog>. Polled daily. KEV entries that touch any Apple framework or AWS-facing SigV4 path are treated as Critical by default.
- **Apple security advisories** — <https://support.apple.com/en-us/HT201222>. Relevant because Spooktacular depends on Virtualization.framework, CryptoKit, Security.framework, and Network.framework.
- **Internal research and red-team exercises** — issues filed via GitHub Security Advisories, never as public issues (see [`SECURITY.md`](../SECURITY.md)).
- **Customer reports** — email to security@spooktacular.app.

## 2. Severity scale (CVSS v3.1-based)

Spooktacular uses the CVSS v3.1 base score with explicit environmental adjustments for the Mac-fleet context:

| Severity | CVSS band | Typical example |
|----------|-----------|------------------|
| **Critical** | 9.0–10.0 | Remote code execution in `HTTPAPIServer`, auth bypass, break-glass scope escalation |
| **High** | 7.0–8.9 | Privilege escalation within a tenant, guest-agent exec-scope weakening, credential disclosure in logs |
| **Medium** | 4.0–6.9 | Information disclosure, cross-tenant timing oracle, DoS requiring authenticated access |
| **Low** | 0.1–3.9 | Hardening improvements, informational disclosure via error messages, documentation errors that mislead operators |

CISA KEV entries are **escalated one band** above their published CVSS unless a written environmental-score rationale is filed — Spooktacular does not normalize down to a lower tier on KEV entries.

## 3. Service-level agreements

SLAs run from the moment Spooky Labs **confirms** the vulnerability — acknowledgment SLAs are separate and covered by [`SECURITY.md`](../SECURITY.md).

| Severity | Release SLA | Advisory publish SLA |
|----------|-------------|----------------------|
| **Critical** | 24 hours from confirmation | Same day as release |
| **High** | 7 days from confirmation | Same day as release |
| **Medium** | 30 days from confirmation | Same day as release |
| **Low** | Next minor release | Batched with release notes |

CISA KEV entries meet these SLAs regardless of internal discovery order. "Release" means a tagged GitHub Release with a notarized binary; "publish" means a GHSA advisory on <https://github.com/Spooky-Labs/spooktacular/security/advisories>.

## 4. Supported versions

- **Latest major release** — always receives security fixes.
- **Previous minor release of the current major** — receives Critical and High fixes until the next minor is 60 days old, at which point it is deprecated.
- **Anything older** — no security support. Customers are expected to upgrade; in pre-1.0 the "latest two" window is tight on purpose to keep the supported surface small.

This matches the table in [`SECURITY.md`](../SECURITY.md) §Supported Versions and supersedes it if they ever diverge.

## 5. Disclosure process

Public disclosure follows **coordinated disclosure** — see [`SECURITY.md`](../SECURITY.md) §Reporting a Vulnerability.

Timeline from confirmation:

1. **Private advisory drafted** on GitHub Security Advisories within 48 hours.
2. **Fix developed** under the SLA above.
3. **Customer pre-notification** for Critical or High vulnerabilities that affect enterprise deployments: 72 hours before public release, via the email distribution list maintained per-tenant. Roadmap Q2 2026.
4. **Public GHSA** issued concurrently with the release.
5. **Post-mortem** published within 14 days for Critical advisories.

Embargo requests from researchers are honored up to 90 days from the date the researcher demonstrates a working proof-of-concept; extensions require written justification.

## 6. Evidence

Every advisory is accompanied by:

- A GHSA entry with CVSS vector, affected versions, fixed version, and references.
- A signed release note in [`CHANGELOG.md`](../CHANGELOG.md) per [Keep-a-Changelog](https://keepachangelog.com/en/1.1.0/).
- An entry in this repository's Security tab.
- Notarized builds with `codesign --verify` evidence (per [`THREAT_MODEL.md`](THREAT_MODEL.md) §5).

Customers who need a pre-release patch for a Critical advisory can request one via security@spooktacular.app.

## 7. Patch-policy cadence review

This document is reviewed:

- **Every release** — against the actual advisories issued that cycle. Divergence (missed SLA, missing evidence) is noted in the release post-mortem.
- **Quarterly** — the CISA KEV polling cadence is re-verified; if CISA changes its SLA guidance the policy catches up in the next quarterly review.

## References

- CISA KEV — <https://www.cisa.gov/known-exploited-vulnerabilities-catalog>
- NVD — <https://nvd.nist.gov/>
- CVSS v3.1 — <https://www.first.org/cvss/v3.1/specification-document>
- GitHub Security Advisories — <https://docs.github.com/en/code-security/security-advisories>
- Keep-a-Changelog — <https://keepachangelog.com/en/1.1.0/>
