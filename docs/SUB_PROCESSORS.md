# Sub-Processors

**Status:** Living document — updated per quarter or on change.
**Owner:** legal@spooktacular.app (interim: security@spooktacular.app).
**Companion document:** [`DATA_PROCESSING_AGREEMENT.md`](DATA_PROCESSING_AGREEMENT.md).

Spooktacular in its **default self-hosted topology** does not introduce sub-processors on Spooky Labs' account. The Controller contracts directly with each infrastructure provider. This page lists those providers and the data each one sees, so procurement can evaluate the chain end-to-end.

Each entry records: purpose, data categories handled, typical region, and a link to the provider's current security attestation.

## 1. AWS (Amazon Web Services, Inc.)

- **Purpose:**
  - **S3 Object Lock** — WORM storage for exported audit records (`S3ObjectLockAuditStore`).
  - **DynamoDB (optional, for multi-region fleets)** — cross-region distributed locks (`DynamoDBDistributedLock`), configured via `SPOOK_DYNAMO_TABLE`.
  - **CloudWatch Logs (optional)** — receives JSONL audit stream when the Controller configures that sink.
- **Data categories:**
  - Audit records (`AuditRecord` JSON lines — actor identity, tenant, action, outcome, ISO-8601 timestamp).
  - Distributed-lock metadata (lock key, holder, version, TTL).
- **Region:** Controller-selected; typically `us-east-1`, `us-west-2`, `eu-west-1` for Fortune-20 multi-region deployments.
- **Security attestation:** <https://aws.amazon.com/compliance/programs/> — SOC 1/2/3, ISO 27001/27017/27018, FedRAMP High (commercial regions), PCI DSS.
- **DPA:** contracted directly by Controller — <https://aws.amazon.com/service-terms/>.

## 2. GitHub (GitHub, Inc., a Microsoft subsidiary)

- **Purpose:**
  - **Actions runners** — self-hosted runner registration and job dispatch (Spooktacular's primary first-class use case per project strategy).
  - **Releases** — binary distribution channel for notarized builds.
  - **Container Registry (`ghcr.io`)** — distribution of the `spook-controller` container image.
  - **Security Advisories** — coordinated disclosure venue (see [`SECURITY.md`](../SECURITY.md)).
- **Data categories:**
  - Runner registration tokens (short-lived; handled via Keychain per [`SECURITY.md`](../SECURITY.md) §"GitHub runner tokens via Keychain").
  - Workflow runtime metadata (job names, run IDs).
  - Source code checked out inside CI jobs (the Controller's code).
- **Region:** GitHub global (primarily US-East region). Enterprise customers may be on GitHub Enterprise Cloud with data residency options.
- **Security attestation:** <https://github.com/security> — SOC 1/2, ISO 27001/27018, CSA STAR, FedRAMP Moderate (Actions).
- **Sub-processor list:** <https://docs.github.com/en/site-policy/privacy-policies/github-data-protection-agreement>.

## 3. Apple (Apple Inc.)

- **Purpose:**
  - **Apple Developer / Notary Service** — notarization of `.app` and `.pkg` builds; staple validation at install time.
  - **App Store Connect / TestFlight** — TestFlight distribution for pre-release builds.
  - **Virtualization.framework and CryptoKit** — runtime; not a sub-processor interaction, but listed for completeness as the platform dependency surface.
- **Data categories:**
  - Build artifacts submitted for notarization (`.app` bundles; no Controller data travels with these).
  - Developer account identity (the Spooky Labs team account).
  - TestFlight tester email addresses, when enterprise customers enroll.
- **Region:** Apple global (primarily US).
- **Security attestation:** <https://support.apple.com/guide/security/welcome/web> — Apple platform security documentation; SOC 2 Type II for iCloud (does not apply to notarization).
- **Terms:** Apple Developer Program License Agreement (signed by Spooky Labs); Apple Services terms apply to TestFlight.

## 4. Identity Provider (Controller-chosen)

- **Purpose:** federated identity for operators — OIDC (JWT) or SAML 2.0.
- **Examples observed in customer deployments:** Okta, Microsoft Entra ID (Azure AD), Google Workspace, PingFederate, AWS IAM Identity Center, self-hosted Keycloak.
- **Data categories:**
  - Operator identity claims (`sub`, `email`, group membership).
  - Signed assertions or tokens (JWT / SAML Response).
- **Region:** Controller's choice, based on their IdP contract.
- **Security attestation:** varies by IdP — the Controller evaluates at procurement.
- **Note:** Spooktacular verifies JWKS and X.509 trust anchors at verification time (see `OIDCTokenVerifier`, `SAMLAssertionVerifier`) and never stores IdP credentials. The IdP is a **Controller sub-processor**, not a Spooky Labs sub-processor.

## 5. TLS PKI (Controller-chosen)

- **Purpose:** issuance of mTLS server and client certificates for controller ↔ node and node ↔ CLI communication.
- **Examples observed:** internal ACME servers (step-ca, Smallstep), AWS Private CA, Vault PKI, commercial CAs (DigiCert, Let's Encrypt for edge use cases).
- **Data categories:** public-key certificate material (not private keys — those stay in the requesting host's Keychain / file mode 0600).
- **Region:** Controller's choice.
- **Attestation:** depends on CA; WebTrust for Certification Authorities is the relevant criterion for public CAs.

## Updates

- This list is reviewed quarterly.
- Material additions (new Spooky Labs sub-processor, changed data-category scope) require 30 days' advance notice to enterprise customers via the notification list maintained under the DPA.
- Controller-chosen sub-processors (IdP, PKI) are the Controller's to manage; this document enumerates them as reference, not as a Spooky Labs commitment.

## References

- AWS compliance — <https://aws.amazon.com/compliance/programs/>
- GitHub trust center — <https://github.com/security>
- Apple platform security guide — <https://support.apple.com/guide/security/welcome/web>
- GDPR Art. 28 sub-processor obligations — <https://gdpr-info.eu/art-28-gdpr/>
