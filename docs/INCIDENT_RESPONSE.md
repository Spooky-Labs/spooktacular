# Incident Response Runbooks

**Status:** Living document — updated per release.
**Owner:** security@spooktacular.app
**Audience:** on-call operators, security-admin role holders, platform-admin role holders.
**Scope:** four high-severity scenarios that map to the trust boundaries in [`THREAT_MODEL.md`](THREAT_MODEL.md). Lower-severity events are handled via the generic response in [`SECURITY.md`](../SECURITY.md#incident-response).

Every runbook follows the same template: **Trigger → Severity & escalation → Containment → Investigation → Remediation → Recovery → Audit trail.** Copy-paste commands are exact; placeholders are `<angle-bracketed>`.

---

## Runbook 1 — Leaked break-glass token

### Trigger

One or more of:

- `AuditRecord` with `action == "bgt.consume"` from an unexpected source IP (check `emitAgentAudit` output at `SPOOK_AGENT_AUDIT_FILE`).
- Operator reports that a `bgt:` blob was pasted into a shared channel (Slack, Jira, screenshot OCR'd by DLP).
- SIEM alert on `authTier == "breakGlass"` outside a change-management window.
- `jti` appearing twice in `UsedTicketCache` telemetry (second attempt would be denied; the first may have succeeded).

### Severity & escalation

- **Severity:** Critical (shell execution inside a guest).
- Page: on-call security-admin within 15 minutes; notify platform-admin and the ticket issuer.
- Open a GitHub Security Advisory draft immediately (private) — see [`SECURITY.md`](../SECURITY.md#reporting-a-vulnerability).

### Containment

Invalidate the ticket on every agent in the affected tenant before any forensics.

```bash
# 1. Identify the ticket's jti + issuer from the audit record.
jq 'select(.action == "bgt.consume") | {jti: .metadata.jti, issuer: .metadata.issuer, tenant: .tenant, ts: .timestamp}' \
  "$SPOOK_AGENT_AUDIT_FILE" | tail -20

# 2. Revoke the offending operator's issuer key fleet-wide
# (single-file delete; no fleet rotation required — see
# SECURITY.md § "Hardware-bound, per-operator break-glass tickets"):
ssh <agent-host> sudo rm \
  /etc/spooktacular/break-glass-keys/<operator>.pem

# 3. Restart the agent to drop any in-process key cache:
ssh <agent-host> sudo launchctl kickstart -k \
  system/com.spooktacular.agent
```

**Roadmap Q3 2026:** a dedicated `spook break-glass revoke --jti <jti>` CLI that populates `UsedTicketCache` across the fleet via a control-plane broadcast. Until that ships, the path above (delete the operator's public-key PEM + kickstart agents) is the supported containment. Code path to extend: `UsedTicketCache.tryConsume(...)` in `Sources/SpookApplication/UsedTicketCache.swift` — add an `invalidate(jti:)` plug-in point.

### Investigation

- Pull every `AuditRecord` where `metadata.jti == <jti>`. Because the ticket is single-use by JTI (see `UsedTicketCache`), there should be exactly one `consume` event; more than one means the cache was bypassed (out-of-process).
- Pull every `AuditRecord` where `authTier == "breakGlass"` in the same tenant for the TTL window (max 1h by codec-enforced policy) and for the 10 minutes after expiry.
- Verify Merkle tree integrity for the audit segment covering the event window: `spook audit verify --from <ts-start> --to <ts-end>` (STH verification path in `MerkleAuditSink`).
- Cross-check with host `log show --predicate 'subsystem == "com.spooktacular.agent" AND category == "audit"' --start <ts>`.

### Remediation

```bash
# Rotate the compromised operator's SEP-bound signing key. The
# private key never leaves the Secure Enclave, but the public key
# allowlist entry is now untrusted.
spook break-glass keygen \
  --keychain-label <operator>-mbp-rotated \
  --public-key ~/<operator>-break-glass-new.pem

# Deploy the new public key to every agent in the tenant.
# Old key stays deleted — do NOT re-add.
for host in $(spook fleet list --tenant <tenant>); do
  scp ~/<operator>-break-glass-new.pem \
    "$host:/etc/spooktacular/break-glass-keys/"
  ssh "$host" sudo launchctl kickstart -k \
    system/com.spooktacular.agent
done
```

If the leak exposed any data the ticket could reach, assume the guest is compromised and follow **Runbook 2** against the affected host(s).

### Recovery

- Confirm the new public key is trusted: `spook break-glass issue --tenant <tenant> --issuer <operator> --ttl 5m --reason "recovery-verification" --dry-run` must produce a ticket that verifies against the new PEM.
- Verify no agent still has the old PEM on disk: `spook fleet exec --tenant <tenant> -- ls /etc/spooktacular/break-glass-keys/` (all outputs must omit the rotated filename).
- Rollback plan: if the new key causes an outage, re-issue an interim software-key ticket via `--signing-key <path>` wrapped in the `AdminPresenceGate` flow documented in [`SECURITY.md`](../SECURITY.md) and plan a second rotation once the root cause is understood.

### Audit trail

- Preserve the `bgt.consume` audit records, the Merkle STH covering them, and the raw `SPOOK_AGENT_AUDIT_FILE` segment for the incident window.
- Capture the file-system state of `/etc/spooktacular/break-glass-keys/` (pre- and post-rotation) via `sudo find /etc/spooktacular/break-glass-keys -type f -exec sha256sum {} +`.
- File the advisory close-out against the GitHub Security Advisory created during escalation.

---

## Runbook 2 — Compromised Mac host

### Trigger

- EDR alert (Jamf Protect, CrowdStrike, SentinelOne) on a Mac running `spook serve`.
- Audit log shows unexpected RBAC decisions (`action == "role:assign"` from a non-`security-admin` actor) — see `handleRoleAPI` in `HTTPAPIServer`.
- `spook doctor` reports mTLS fingerprint mismatch or TLS hot-reload firing unexpectedly (`reloadTLS` path).
- Host IMDS identity drift on EC2 Mac (see `docs/EC2_MAC_DEPLOYMENT.md`).

### Severity & escalation

- **Severity:** Critical.
- Page: on-call security-admin + platform-admin immediately.
- Declare an incident in the customer-facing status channel if tenants other than the operator's are affected.

### Containment

```bash
# 1. Drain GitHub Actions runners on the host (prevents new jobs
# from landing on compromised VMs):
spook runners drain --host <hostname> --timeout 5m

# 2. Cordon the node if controller-managed:
kubectl cordon <node-name>

# 3. Network-isolate the host (pfctl). Keep SSH for responders,
# drop everything else:
sudo pfctl -a com.spooktacular/quarantine -f - <<'EOF'
block drop in all
block drop out all
pass in proto tcp from <responder-bastion-cidr> to any port 22
pass out proto tcp from any to <responder-bastion-cidr> port 22
EOF
sudo pfctl -E

# 4. Stop spook serve but keep the host powered on for forensics:
sudo launchctl unload \
  /Library/LaunchDaemons/com.spooktacular.server.plist
```

### Investigation

- Verify audit integrity before trusting any log on the host:

  ```bash
  spook audit verify \
    --from <last-known-good-ts> \
    --to now
  ```

  The Merkle STH chain (`MerkleAuditSink.signedTreeHead`) is signed by the Secure-Enclave-bound key; a host compromise cannot forge past STHs. Divergence between the on-host audit tree and the S3 Object Lock copy (`S3ObjectLockAuditStore`) proves tampering.

- Inspect the append-only file's `UF_APPEND` flag is still set: `ls -lO "$SPOOK_AUDIT_FILE"` — if `uappnd` is missing, the kernel-enforced append-only guarantee was defeated (root-level escalation).
- Pull `log collect --last 24h` into an offline bundle for later analysis.
- Check `launchctl print system/com.spooktacular.*` for daemons added since the last known-good plist inventory.

### Remediation

EC2 Mac: force-replace the root volume. This is the only remediation that survives a kernel-persistent compromise.

```bash
# Using the EC2 CLI from a trusted workstation:
INSTANCE_ID=<i-…>
aws ec2 stop-instances --instance-ids "$INSTANCE_ID"
aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
aws ec2 replace-root-volume-task \
  --instance-id "$INSTANCE_ID" \
  --image-id <trusted-amzn-mac-ami> \
  --delete-replaced-root-volume
aws ec2 start-instances --instance-ids "$INSTANCE_ID"
```

Bare-metal or co-located Mac: boot into Recovery, run `csrutil status` (must be `enabled`), erase the data volume, reinstall macOS from a known-good IPSW, restore bundles from backup **only** after integrity verification (SHA-256 against the last Merkle record before the incident).

After volume replacement:

```bash
# Rotate the mTLS client/server cert (SEP-unwrapping fails on the
# new install, so the old private key is useless):
spook certs rotate --host <hostname>

# Reconcile tenant state — any VM that was running on the
# compromised host must be recreated, not restored:
spook tenant reconcile --drop-orphans
```

### Recovery

- Bring the host back into the fleet only after `spook doctor` reports all preflight checks green (`ProductionPreflight.validate()`).
- Uncordon: `kubectl uncordon <node-name>`.
- Monitor for 48 hours with alert thresholds halved before declaring the incident closed.
- Rollback plan: if the new AMI introduces a regression, pin the previous AMI via the controller's node-template and re-run `replace-root-volume-task`; never re-attach the original volume.

### Audit trail

- Archive the offline `log collect` bundle and the pre-incident Merkle STH to the same bucket used for S3 Object Lock exports.
- Snapshot the DynamoDB lock table (`SPOOK_DYNAMO_TABLE`) to preserve evidence of any lock-holder identity spoofing.
- File the advisory with CVSS scoring per [`PATCH_POLICY.md`](PATCH_POLICY.md).

---

## Runbook 3 — Merkle audit signing key compromise

### Trigger

- Secure Enclave attestation failure on `SecureEnclave.P256.Signing.PrivateKey` load (only possible if the SEP is mis-provisioned or the key was replaced with a software key).
- Alert: STH signed by a public key not on the operator-published allowlist.
- Software-key path (`SPOOK_AUDIT_SIGNING_KEY_PATH`) file permissions drift from `0600` (`AuditSinkFactory.loadOrCreateSigningKey` refuses to boot, so this surfaces as a startup failure).

### Severity & escalation

- **Severity:** Critical (non-repudiation collapse).
- Page: on-call security-admin + auditor.
- Notify every downstream verifier (SOC 2 auditor, SIEM operator, customer auditors with `AUDIT_STATUS.md` rights) that an STH-key rotation is in progress.

### Containment

Do **not** delete the old key until step 4 completes — the segment signed with it must stay verifiable.

```bash
# 1. Freeze audit writes briefly (operator-only window):
spook audit freeze --reason "sth-key-rotation"

# 2. Generate a new SEP-bound key on a trusted Apple-Silicon
# controller host. The private key is generated inside the SEP and
# is non-exportable (see SECURITY.md §"Tamper-evident audit"):
spook audit keygen \
  --keychain-label spook-audit-$(date +%Y%m%d) \
  --public-key ./audit-pub-new.pem

# 3. Publish the new public key alongside the old one:
cp audit-pub-new.pem \
  /var/spool/spooktacular/audit-pub-keys/
```

### Investigation

- Collect every STH from the suspect window: `spook audit list-sths --from <ts>`.
- Verify each with the **old** public key — genuine STHs remain valid; a forged one fails. Preserve the separation: never verify old segments with the new key.
- Query downstream verifiers (SIEM, S3 Object Lock index) for copies of the same STHs; divergence between host-local and off-host copies localizes the compromise to the host.

### Remediation — canary chain-link

Per RFC 6962 §3.5 the STH TBS structure does not itself chain trees — Spooktacular's convention is to append a **canary record** whose `AuditRecord.metadata` embeds the old STH root, old public-key fingerprint, and a human-readable note, then sign the next tree head with the new key. Verifiers walk the canary to transition key contexts.

```bash
# 4. Emit the canary record (this call refuses unless both public
# keys are on disk — prevents accidental lockout):
spook audit chain-rotate \
  --old-pub /var/spool/spooktacular/audit-pub-keys/audit-pub-old.pem \
  --new-pub /var/spool/spooktacular/audit-pub-keys/audit-pub-new.pem \
  --reason "incident-<ticket-id>"

# 5. Unfreeze:
spook audit unfreeze

# 6. After 30 days (or a customer-defined retention window),
# lock out the old key by moving it to an "archived" path that
# the loader refuses to use for signing but still distributes for
# verification:
sudo mv /var/spool/spooktacular/audit-pub-keys/audit-pub-old.pem \
  /var/spool/spooktacular/audit-pub-keys-archive/
```

**Roadmap Q3 2026:** embed the canary emit step directly in `AuditSinkFactory` so every key rotation produces a chain-link record by default.

### Recovery

- Confirm `spook audit verify --from <last-pre-rotation> --to now` passes without warnings. The verifier must successfully cross the canary.
- Republish the new public key on the operator's transparency log and in [`AUDIT_STATUS.md`](AUDIT_STATUS.md).
- Rollback plan: the old public key remains published for verification; if the new key itself is found to be compromised, repeat this runbook — do **not** revert to the old key.

### Audit trail

- Preserve both public keys forever. Long-lived verifiers (customers auditing a year later) need the old key to verify historical segments.
- Record the canary record's id, the pre-rotation STH, and the post-rotation STH in the incident ticket.
- Append the rotation event to [`AUDIT_STATUS.md`](AUDIT_STATUS.md) under "Key rotations."

---

## Runbook 4 — S3 Object Lock misconfiguration

### Trigger

- CloudWatch metric `AuditExportFailure` (emitted by `S3ObjectLockAuditStore` via the metric interface in `SpooktacularConfig`) exceeds zero for 5 consecutive minutes.
- AWS Config rule `s3-bucket-object-lock-enabled` transitions to `NON_COMPLIANT` on the audit export bucket.
- A `PutObject` returns `400 InvalidRequest` with `A retention date must be supplied with Object Lock Retain Until Date` — indicates the IAM policy or bucket default retention drifted.

### Severity & escalation

- **Severity:** High (audit chain still intact via append-only + Merkle + OSLog; WORM second sink is degraded).
- Page: on-call platform-admin. Security-admin is looped in at the 1-hour mark if the secondary sink cannot be restored.

### Containment

```bash
# 1. Keep writing to the primary sinks — they are still WORM-ish
# via UF_APPEND + SEP-signed STH. Flip exports to the dual-audit
# secondary sink until the primary is fixed:
spook audit sink set --primary file --secondary s3 \
  --swap

# 2. Snapshot the last-known-good bucket policy + retention config
# for diff:
aws s3api get-bucket-policy --bucket "$AUDIT_BUCKET" \
  > /tmp/policy-pre.json
aws s3api get-object-lock-configuration --bucket "$AUDIT_BUCKET" \
  > /tmp/object-lock-pre.json
```

### Investigation

- Compare `/tmp/policy-pre.json` and `/tmp/object-lock-pre.json` against the infrastructure-as-code source of truth (Terraform/CloudFormation). Diffs reveal whether this was a console-driven change or an IAM drift.
- Check CloudTrail for `PutBucketPolicy`, `PutObjectLockConfiguration`, and `DeleteBucketPolicy` events on the bucket over the last 30 days. Correlate with the principal and session identity.
- Verify the primary sink captured every record during the outage: compare Merkle tree size pre- and post-incident, and compare against the record count shipped to the SIEM webhook (`WebhookAuditSink`).

### Remediation

```bash
# 3. Re-apply the canonical bucket policy + object-lock config
# from IaC (this is the only path — no ad-hoc policies):
terraform -chdir=deploy/terraform/audit-bucket apply \
  -auto-approve

# 4. Backfill missing records with a recovery tag. The backfill
# path uses AuditRecord's explicit-id init so record ids and
# timestamps from the primary sink are preserved 1:1 (see
# MerkleAuditSink.record path in THREAT_MODEL.md §4.3):
spook audit backfill \
  --from <outage-start-ts> \
  --to   <outage-end-ts> \
  --tag  "recovered-from-incident=<ticket-id>"
```

Every backfilled object in S3 MUST carry the `recovered-from-incident` tag; dashboards and compliance queries filter on this tag to distinguish real-time vs. replayed records.

### Recovery

- Verify `aws s3api get-object-retention --bucket "$AUDIT_BUCKET" --key <recent-object>` returns `COMPLIANCE` mode with a future `RetainUntilDate`.
- Run `spook audit verify --from <outage-start-ts> --to now` — Merkle inclusion proofs must pass for every backfilled record.
- Reset CloudWatch alarms and re-enable AWS Config rule evaluation.
- Rollback plan: if the re-applied Terraform introduces a new failure mode, roll forward (change the module) — never downgrade the bucket to a non-WORM configuration.

### Audit trail

- Preserve CloudTrail export of the incident window in the same S3 Object Lock bucket under `cloudtrail/incident-<ticket-id>/`.
- Archive `/tmp/policy-pre.json` and `/tmp/object-lock-pre.json` to the incident ticket.
- Record the incident + remediation in [`AUDIT_STATUS.md`](AUDIT_STATUS.md) under "Notable audit-pipeline events."

---

## References

- OWASP ASVS — <https://owasp.org/www-project-application-security-verification-standard/>
- NIST SP 800-53 Rev 5 (IR-4, IR-6, AU-9) — <https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-53r5.pdf>
- NIST SP 800-61 Rev 2 (Computer Security Incident Handling Guide) — <https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-61r2.pdf>
- RFC 6962 (Certificate Transparency) — <https://datatracker.ietf.org/doc/html/rfc6962>
- AWS S3 Object Lock — <https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html>
