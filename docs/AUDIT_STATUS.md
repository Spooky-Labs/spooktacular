# Audit and Compliance Status

**Status:** Living document — updated per quarter.
**Owner:** security@spooktacular.app
**Audience:** prospective customers, their procurement and legal teams, their internal auditors.

This page records Spooktacular's current posture against the audit regimes that Fortune-20 buyers ask about. Claims here map directly to controls in [`SECURITY.md`](../SECURITY.md), [`THREAT_MODEL.md`](THREAT_MODEL.md), and [`OWASP_ASVS_AUDIT.md`](OWASP_ASVS_AUDIT.md). Dates that are in the future are commitments, not marketing.

## SOC 2 Type II

- **Status:** In progress.
- **Target completion:** Q3 2026.
- **Audit firm:** TBD (RFP in progress).
- **In-scope trust-services criteria:** CC1 through CC9, with emphasis on:
  - **CC6 (logical access)** — RBAC (`RBACAuthorization`), federated identity (`OIDCTokenVerifier`, `SAMLAssertionVerifier`), mTLS, Keychain-backed key custody.
  - **CC7 (monitoring)** — Merkle audit tree (`MerkleAuditSink`), append-only file store (`AppendOnlyFileAuditStore`), S3 Object Lock (`S3ObjectLockAuditStore`), SIEM webhook (`WebhookAuditSink`).
  - **CC8 (change management)** — signed commits (roadmap — see below), branch protection, release notarization.
- **Evidence package:**
  - Merkle audit logs with SEP-signed STHs — proves non-repudiation of operator actions.
  - RBAC decision logs — proves deny-by-default and least-privilege enforcement.
  - Peer-reviewed pull-request history — proves change-management over source.
  - Production preflight refusal records (`ProductionPreflight.validate()`) — proves fail-closed posture at startup.
- **Roadmap to first report:**
  - Q1 2026 — readiness assessment and gap analysis.
  - Q2 2026 — observation period begins.
  - Q3 2026 — Type II report issued.
- **Signed commits:** roadmap Q2 2026 — currently commits are author-attributed but not cryptographically signed; `CODEOWNERS` is enforced, but GPG/SSH commit signing is pending a key-management story for the maintainer set.

## ISO/IEC 27001

- **Status:** Roadmap.
- **Target:** ISO 27001:2022 certification, Q4 2026.
- **Current alignment:** the controls in Annex A that overlap with SOC 2 CC are covered by the same evidence package. A formal Statement of Applicability is pending the SOC 2 Type II readiness engagement.
- **Dependencies:** stable information-security-management-system (ISMS) documentation set; the security, threat-model, incident-response, and patch-policy documents in this repository form the operational core of the ISMS.

## FedRAMP

- **Status:** Moderate-baseline alignment documented; formal authorization **not pursued pre-1.0**.
- **Rationale:** FedRAMP authorization requires a CSP-sponsored ATO and a 3PAO assessment. Spooktacular is self-hosted by the customer in its default topology, so a managed-service authorization is the appropriate vehicle — that service is itself on the Q4 2026 roadmap.
- **Mapping:** control mappings are published in [`OWASP_ASVS_AUDIT.md`](OWASP_ASVS_AUDIT.md). The overlap with NIST SP 800-53 Rev 5 Moderate controls exceeds 80%, but gap analysis is done per-customer during procurement.
- **Reference:** NIST SP 800-53 Rev 5 — <https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-53r5.pdf>.

## HIPAA

- **Status:** BAA available on request for enterprise customers processing ePHI.
- **Scope:** Spooktacular does not itself store ePHI — it runs customer workloads inside VMs. The BAA covers Spooky Labs' support interactions where a customer shares ePHI inadvertently (crash bundles, support tickets).
- **Safeguards in place:** the administrative, physical, and technical safeguards listed in [`SECURITY.md`](../SECURITY.md) map to the HIPAA Security Rule at 45 CFR §164.308–312. A mapping table is provided under NDA.
- **Contact:** legal@spooktacular.app (interim: security@spooktacular.app) to request the BAA template.

## PCI-DSS

- **Status:** Not applicable.
- **Rationale:** Spooktacular does not process, store, or transmit cardholder data. Customer workloads running inside VMs are customer-scoped — if a customer runs PCI workloads inside Spooktacular VMs, their CDE (cardholder-data environment) is defined by their own scoping, and Spooktacular provides isolation controls (multi-tenant boundary, audit, mTLS) that can be cited in the customer's RoC. Spooky Labs is not a PCI-SSF-validated service provider.

## External validation cadence

| Activity | Cadence | Last run | Next target |
|----------|---------|----------|-------------|
| Third-party penetration test | Annual | Not yet run | Q2 2026 |
| Red-team break-glass exercise | Annual | Not yet run | Q3 2026 |
| Dependency SCA scan | Per-commit (Dependabot) | Continuous | — |
| SBOM publication | Per-release | Roadmap | First release after Q1 2026 |
| CIS Benchmark scan of `.app` bundle | Annual | Not yet run | Q2 2026 |
| Reproducible build verification | Per-release | Roadmap | Q3 2026 |

## Key rotations

Record of STH signing-key rotations, per Runbook 3 in [`INCIDENT_RESPONSE.md`](INCIDENT_RESPONSE.md). Each entry links to the canary record and the pre/post STHs:

- No rotations recorded yet.

## Notable audit-pipeline events

Record of audit-pipeline failures and recoveries per Runbook 4 in [`INCIDENT_RESPONSE.md`](INCIDENT_RESPONSE.md):

- No events recorded yet.

## Contact

- Audit documentation requests: security@spooktacular.app with subject `AUDIT: <regime>`.
- NDA-gated materials (SOC 2 reports, CAIQ responses, BAAs): via the same email; expect a 5-business-day turnaround.
