# Data Processing Agreement (Template)

**Status:** Template. Customer-specific negotiation required before signature.
**Owner:** legal@spooktacular.app (pending — interim: security@spooktacular.app).
**Version:** v0 draft for pre-1.0 customers.

This document is a **starting point** for a GDPR Art. 28-aligned Data Processing Agreement between Spooky Labs ("Processor") and a customer organization ("Controller"). Every blank and placeholder must be negotiated per-customer; nothing here is legally binding absent a signed counterpart.

Reference: GDPR Art. 28 — <https://gdpr-info.eu/art-28-gdpr/>.

---

## 1. Parties

- **Processor:** Spooky Labs (legal-entity TBD). Operator of the Spooktacular software. Contact: legal@spooktacular.app.
- **Controller:** `<customer legal entity>`. Primary contact: `<customer privacy officer>`.

Spooktacular is delivered as **software the Controller self-hosts**. Spooky Labs does not host Controller data on its own infrastructure for the default deployment topology. Sub-processors listed in [`SUB_PROCESSORS.md`](SUB_PROCESSORS.md) are contracted by the Controller, not by Spooky Labs. This DPA applies only to data that flows through Spooky Labs' systems — notably crash reports, support interactions, and any future managed-service offering.

## 2. Data categories processed

| Category | Description | Source |
|----------|-------------|--------|
| **Source code** | Git checkouts inside guest VMs during CI jobs | Controller (via GitHub Actions runners) |
| **Signing keys** | Apple code-signing certificates, notarization credentials | Controller's Keychain |
| **Audit logs** | `AuditRecord` entries (actor identity, tenant, action, outcome, timestamp) | Spooktacular control plane |
| **Workload output** | Build artifacts, test reports, logs produced inside VMs | Controller |
| **Operator identity** | OIDC/SAML claims, mTLS certificate subjects, Keychain-derived usernames | Controller's IdP |

Spooky Labs processes these categories **only** when the Controller voluntarily shares them with Spooky Labs (for support tickets, crash bundles, or a future managed service). The operator identity captured in Controller-hosted audit logs does **not** flow to Spooky Labs by default — Spooktacular has zero telemetry (see [`SECURITY.md`](../SECURITY.md)).

## 3. Processing purposes

Spooky Labs processes Controller data only to:

- Provide software support and diagnose defects reported via [`SUPPORT.md`](../SUPPORT.md).
- Investigate security reports filed under [`SECURITY.md`](../SECURITY.md).
- Publish anonymized, aggregated metrics for engineering roadmap planning (requires opt-in).

Any other use requires written Controller authorization.

## 4. Sub-processors

See [`SUB_PROCESSORS.md`](SUB_PROCESSORS.md). The Controller contracts each sub-processor directly (AWS, GitHub, Apple, Controller-chosen IdP). Spooky Labs does not introduce additional sub-processors in the default topology. A managed-service offering (roadmap Q4 2026) will require a separate DPA revision with the added sub-processors enumerated.

## 5. Data retention

| Asset class | Retention period | Storage |
|-------------|------------------|---------|
| Crash bundles uploaded to Spooky Labs | 90 days | Ticket system, encrypted at rest |
| Support correspondence | 2 years | Ticket system |
| Security advisories | Permanent (public) | GitHub Security Advisories |
| Source code snippets shared for debugging | Deleted on ticket close | Ticket system |
| Customer-hosted audit logs | Controller-defined (see [`AUDIT_STATUS.md`](AUDIT_STATUS.md) for S3 Object Lock retention guidance) | Controller infrastructure |

Controllers define their own retention for anything inside their self-hosted deployment. Spooktacular's audit sinks (`JSONFileAuditSink`, `MerkleAuditSink`, `S3ObjectLockAuditStore`) expose retention as operator configuration; defaults do not auto-purge.

## 6. Deletion on request

On written Controller request:

1. Spooky Labs deletes all Controller data from its support and ticketing systems within **30 days**.
2. Spooky Labs provides a deletion attestation identifying each artifact deleted (by SHA-256 hash where possible).
3. Audit logs inside the Controller's self-hosted deployment are the Controller's responsibility to delete; the Merkle audit trail is append-only by design (see [`THREAT_MODEL.md`](THREAT_MODEL.md) §4.3).
4. Security advisories related to the Controller's reported vulnerabilities remain published to protect the broader user base.

## 7. Security measures

Spooky Labs implements the measures documented in [`SECURITY.md`](../SECURITY.md), [`THREAT_MODEL.md`](THREAT_MODEL.md), and [`docs/DATA_AT_REST.md`](DATA_AT_REST.md). Notable controls:

- TLS 1.3 floor with hot-reload for control-plane traffic.
- P-256 ECDSA request signing with Secure-Enclave-bound keys where hardware permits.
- RFC 6962 Merkle audit tree with Secure-Enclave-signed tree heads.
- Constant-time credential comparison for all bearer-token paths.
- Keychain-backed secret storage via `SecItemAdd` with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.

## 8. Data-subject rights

Spooky Labs will assist the Controller in responding to data-subject access, rectification, and erasure requests within the timeframes mandated by applicable law (GDPR Art. 12 — 1 month, extensible by 2 months for complex requests). Because Spooky Labs does not hold Controller operational data by default, most requests terminate at the Controller's own systems; Spooky Labs responds to tickets about its own processing within 14 days.

## 9. Audit rights

- **Documentation-based:** the Controller may request copies of [`SECURITY.md`](../SECURITY.md), [`THREAT_MODEL.md`](THREAT_MODEL.md), [`AUDIT_STATUS.md`](AUDIT_STATUS.md), and the most recent SOC 2 Type II report (once issued) at no cost.
- **Questionnaire-based:** Spooky Labs responds to CAIQ, SIG Core, or equivalent questionnaires once per year per Controller.
- **On-site:** available for enterprise customers under NDA, scheduled no more than once per 12 months absent a material incident.
- **Regulator cooperation:** Spooky Labs cooperates with supervisory authorities per GDPR Art. 31.

## 10. Breach notification

- Spooky Labs notifies the Controller of a personal-data breach affecting Controller data **within 72 hours** of confirmed detection, consistent with GDPR Art. 33.
- The notification includes: nature of the breach, categories and approximate number of data subjects, likely consequences, and remediation measures taken or proposed.
- A follow-up report is provided within 14 days with root-cause analysis and incident-response evidence per [`INCIDENT_RESPONSE.md`](INCIDENT_RESPONSE.md).

## 11. International transfers

Spooktacular software is distributed from the United States. Data movement between Controller and Spooky Labs occurs only when the Controller initiates support contact. For EU Controllers, the SCCs (Commission Implementing Decision (EU) 2021/914) apply by reference; Module 2 (Controller → Processor) governs when Spooky Labs holds Controller data during a support interaction.

## 12. Liability and indemnification

**To be negotiated per customer.** The template intentionally leaves caps and carve-outs blank; procurement reviews require these to be written against the commercial agreement, not inherited from a standard form.

## 13. Governing law and venue

**To be negotiated per customer.** Default placeholder: the laws of `<customer-chosen US state>`, venue in `<courts of that state>`, with arbitration under AAA Commercial Rules as a customer-selectable alternative.

## 14. Term and termination

- This DPA remains in effect as long as Spooky Labs processes Controller data.
- Either party may terminate for material uncured breach with 30 days' written notice.
- On termination, clauses 6 (Deletion) and 9 (Audit rights, for 12 months post-termination) survive.

---

**Signatures required before this DPA binds either party.** The document is a template; customer-specific redlines take precedence.
