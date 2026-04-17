# Export Control and Sanctions Notice

**Status:** Informational — does not substitute for legal advice.
**Owner:** legal@spooktacular.app (pending — interim: security@spooktacular.app).
**Audience:** re-distributors, integrators, and end-users subject to US export control or sanctions law.

Spooktacular is published under the MIT License. The license grants copyright permissions; it does **not** relieve any downloader, re-distributor, or end-user of obligations under US export control or sanctions regulations.

## 1. EAR classification (preliminary)

- **Preliminary self-classification:** Export Control Classification Number (ECCN) `5D002` (information-security software), likely eligible for License Exception ENC (EAR §740.17) as publicly available mass-market encryption software. The open-source Notification ("TSU" per §742.15(b)) applies to the publicly available source.
- **Reference:** 15 CFR §740.17 — <https://www.ecfr.gov/current/title-15/subtitle-B/chapter-VII/subchapter-C/part-740>.
- **Caveat:** this classification is preliminary and based on the author's reading of the EAR as of the document date. A formal commodity-classification determination (CCATS) has **not** been obtained. Operators subject to strict export compliance (federal contractors, dual-use reviews) should request their own counsel's review before deployment.
- **Path to formal review:** Spooky Labs will file a Commodity Classification Automated Tracking System (CCATS) request in the quarter preceding 1.0, targeting Q3 2026. The outcome will be published here.

## 2. OFAC — prohibited destinations and persons

US-law end-users may **not** export, re-export, or provide Spooktacular to:

- Comprehensively sanctioned countries and regions, currently (as of publication): **Cuba, Iran, North Korea, Syria, and the Crimea, Donetsk, and Luhansk regions of Ukraine**. Consult the OFAC Sanctions Programs and Country Information page for the current list — <https://ofac.treasury.gov/sanctions-programs-and-country-information>.
- Any person or entity on OFAC's Specially Designated Nationals and Blocked Persons (SDN) list — <https://ofac.treasury.gov/specially-designated-nationals-and-blocked-persons-list-sdn-human-readable-lists>.
- Any person or entity on the BIS Entity List, Unverified List, or Denied Persons List — <https://www.bis.doc.gov/index.php/policy-guidance/lists-of-parties-of-concern>.

This list changes; operators are responsible for screening at the time of export. OFAC lists are the primary authority — if this document lags, OFAC wins.

## 3. End-user compliance clause

By downloading, installing, or using Spooktacular:

1. The end-user represents that they are not located in, under the control of, or a national or resident of any country or region listed under §2.
2. The end-user represents that they are not listed on any denied-party screening list referenced under §2.
3. The end-user accepts responsibility for compliance with all applicable export control and sanctions regulations in their jurisdiction (including but not limited to EU Dual-Use Regulation 2021/821 for EU end-users, and UK Export Control Order 2008).
4. The MIT License's grant of rights does **not** authorize use contrary to §§1–3.

Spooky Labs maintains the right to refuse service (GitHub distribution, support, advisories) to any party in violation of the above.

## 4. Cryptographic inventory

Cryptographic primitives in Spooktacular (relevant to ECCN 5D002 classification, Section 5.A.2 of the Wassenaar Arrangement dual-use list):

| Primitive | Use | Implementation |
|-----------|-----|----------------|
| **P-256 ECDSA** (FIPS 186-4) | HTTP API request signing, break-glass tickets, Merkle STH signing | `CryptoKit` — software + `SecureEnclave.P256.Signing.PrivateKey` where hardware permits |
| **Ed25519** (RFC 8032) | Reserved for future use (historical STH path) | `CryptoKit` |
| **TLS 1.3** (RFC 8446) | Controller ↔ node, API ↔ client | Apple `Network.framework` / `NIOSSL` bindings; TLS 1.2 floor rejected at init and hot reload |
| **AES-GCM (128 / 256)** (NIST SP 800-38D) | At-rest protection via FileVault + per-file AES (CUFUA on portable Macs) | Apple platform-provided |
| **SHA-256, SHA-384** (FIPS 180-4) | Merkle tree hashing (RFC 6962), request-body digest in signed-request header, TLS suite | `CryptoKit` |
| **HMAC-SHA256** (RFC 2104) | AWS SigV4 signing for DynamoDB and S3 | Hand-rolled, no AWS SDK |
| **HKDF** (RFC 5869) | Key derivation in session-scoped paths | `CryptoKit` |
| **ChaCha20-Poly1305** (RFC 8439) | TLS 1.3 cipher suite selection (mobile-friendly path) | `Network.framework` |

No custom or proprietary cryptography. All primitives are standards-based and use Apple's audited implementations (CryptoKit, Security.framework, Network.framework) or widely reviewed specifications where hand-rolled (SigV4).

## 5. Data-at-rest and key-custody disclosures

- Private keys for P-256 request signing, break-glass ticket signing, and Merkle STH signing are generated **inside the Apple Secure Enclave** on hardware where available, and are non-exportable by hardware policy.
- Software-keyed fallbacks (headless hosts without SEP) use PEM-encoded P-256 keys at file mode `0600`, created atomically via `open(2) O_CREAT | O_EXCL | O_NOFOLLOW`. The loader refuses to open keys with weaker permissions.
- See [`SECURITY.md`](../SECURITY.md) and [`docs/DATA_AT_REST.md`](DATA_AT_REST.md) for operational detail.

## 6. Updates and review

This notice is reviewed:

- **Every release** — cryptographic inventory must match the SBOM (roadmap Q3 2026) and the controls enumerated in `SecurityControlInventory`.
- **Quarterly** — sanctions-list references re-verified against primary sources (OFAC, BIS).
- **On regulatory change** — within 30 days of a published update to the EAR or a relevant OFAC designation.

## References

- 15 CFR Part 740 (License Exceptions, including ENC) — <https://www.ecfr.gov/current/title-15/subtitle-B/chapter-VII/subchapter-C/part-740>
- 15 CFR Part 774 (Commerce Control List, ECCN 5D002) — <https://www.ecfr.gov/current/title-15/subtitle-B/chapter-VII/subchapter-C/part-774>
- OFAC — <https://ofac.treasury.gov/>
- BIS lists of parties of concern — <https://www.bis.doc.gov/index.php/policy-guidance/lists-of-parties-of-concern>
- Wassenaar Arrangement — <https://www.wassenaar.org/>
