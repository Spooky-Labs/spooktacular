# Spooktacular Hardened Deployment Guide

**Audience:** Operators deploying Spooktacular in a Fortune-20 / regulated environment.
**Goal:** Walk from empty host to a production-grade deployment without a single "we'll fix it later."
**Posture:** Fail-closed — if a required control is missing, the process refuses to start. No silent degradation.

The rest of this document is organized as:

1. **Pre-flight checklist** — stop here if any line is unchecked.
2. **The minimum-safe environment** — the exact env vars that flip every control on.
3. **Anti-footgun patterns** — known ways operators accidentally disable security, and how to avoid them.
4. **Reference `launchd` plist** — tested, copy-paste ready.
5. **Verification** — how to prove to an auditor that each control is live.
6. **Rotation & drills** — what to do on day-180, day-365, and on incident.

---

## 1. Pre-flight checklist

Every item is **required for production**. A cell marked "dev-only" means the code will accept it, but your change-control board should not.

The **Doctor** column indicates how `spook doctor --strict` surfaces each row — `Y` (fully automated), `manual` (printed with a `?` marker because the CLI cannot introspect an external system), and `N` (not yet automated). Every strict-mode output line is prefixed `[##]` so the number matches this table exactly.

| # | Control | How to verify | Doctor (`spook doctor --strict`) |
|---|---------|---------------|----------------------------------|
| 1 | TLS certificate + key configured | `SPOOK_TLS_CERT_PATH`, `SPOOK_TLS_KEY_PATH`, `SPOOK_TLS_CA_PATH` all set and readable by the daemon user | Y — env set + file readable |
| 2 | mTLS (client cert required) | CA path set, server presents cert, client cert is required on every request | Y — `SPOOK_TLS_CA_PATH` readable |
| 3 | TLS 1.3 floor | No explicit config needed — enforced in code, hot-reload preserves it | Y — TLS-1.3 handshake probed on port 8484 (warn when serve is offline) |
| 4 | API bearer token in Keychain | `security find-generic-password -a spook-api -s com.spooktacular.api` returns a value | Y — Keychain probe via `SecItemCopyMatching`; env-var fallback is flagged as warning |
| 5 | Guest-agent tokens in Keychain | `SPOOK_AGENT_TOKEN` / `SPOOK_AGENT_RUNNER_TOKEN` / `SPOOK_AGENT_READONLY_TOKEN` — **not** on disk in plaintext | Y — env presence OR Keychain entry `com.spooktacular.agent` |
| 6 | RBAC active | `SPOOK_RBAC_CONFIG` points at a readable JSON file, or `SPOOK_MACOS_GROUP_MAPPING` is set | Y — file readable OR group mapping set |
| 7 | Federated IdP configured | `SPOOK_IDP_CONFIG` JSON exists with at least one OIDC/SAML provider | Y — `SPOOK_IDP_CONFIG` readable |
| 8 | JWKS pinned (strongest) OR trusted mirror | Either `staticJWKSPath` or `jwksURLOverride` on every OIDC provider | Y — every OIDC provider parsed out of the config must carry one of the two fields |
| 9 | Audit JSONL enabled | `SPOOK_AUDIT_FILE` set, path is writable, tail the file to confirm records flow | Y — env set + parent directory writable |
| 10 | Append-only audit backing | `SPOOK_AUDIT_IMMUTABLE_PATH` set; after first write, `ls -lO` shows `uappnd` on the file | Y — `stat(2)` on the path checks `UF_APPEND` |
| 11 | Merkle signing key persisted | `SPOOK_AUDIT_SIGNING_KEY` points at a path with mode 0600; verify with `stat -f '%Op' /path` — must be `100600` | Y — POSIX mode 0600 assertion via `FileManager.attributesOfItem` |
| 12 | S3 Object Lock audit copy | `SPOOK_AUDIT_S3_BUCKET` set, bucket is in Object-Lock **Compliance mode** with a retention period | manual — CLI prints `?` with the bucket name + `aws s3api get-object-lock-configuration` one-liner (AWS call not issued from doctor) |
| 13 | Distributed lock backend | `SPOOK_DYNAMO_TABLE` (cross-region) or `SPOOK_K8S_API` (cluster) — **not** the file fallback, in fleets of ≥ 2 hosts | Y — DynamoDB / K8s / file fallback all classified |
| 14 | Tenancy mode set | `SPOOK_TENANCY_MODE=multi-tenant` for any fleet with more than one team's workloads | Y — echoes the configured mode |
| 15 | Insecure mode is OFF | `SPOOK_INSECURE_CONTROLLER` is unset and `spook serve --insecure` is never in a unit file | Y — env var guard |
| 16 | Hardened Runtime + notarization | `codesign -d --verbose=4 /usr/local/bin/spook` shows `flags=0x10000(runtime)` and `TeamIdentifier` | Y — invokes `codesign -d --verbose=4` on `$ARGV[0]` |
| 17 | Code-signing timestamp | Same output shows `Signed Time=…` (from `--timestamp` in `build-app.sh`) | Y — same codesign output parsed for `Signed Time=` / `Timestamp=` |
| 18 | Only Apple SDKs in dependency tree | `swift package show-dependencies --format json` returns an empty `dependencies` array | manual — build-time; doctor prints `?` with the one-liner to run locally |

### Doctor-only probes (numbered ≥ 19)

`spook doctor --strict` also surfaces reviewer-flagged probes that aren't in the 18-item hardening checklist but are easy failure modes in practice:

| Doctor # | What it probes |
|----------|----------------|
| 19 | **SAML assertion verifier readiness** — every `saml`-typed provider in `SPOOK_IDP_CONFIG` must point at a readable `metadataPath` or `signingCertPath`, else signature verification silently fails open at first request |
| 20 | **IAM binding store writability** — `SPOOK_IAM_BINDINGS_CONFIG` path / parent directory can be opened for read+write; if not, `/v1/vms/:name/identity-token` returns empty bindings instead of minting |
| 21 | **Audit sink can-write probe** — opens `SPOOK_AUDIT_FILE` for append (creating it if absent + permitted) so permissions mismatches surface at doctor time instead of on the first authentic request |
| 22 | **Signed-request verifier key material** — `SPOOK_API_PUBLIC_KEYS_DIR` contains ≥ 1 `.pem` / `.pub` file; an empty directory silently degrades every signed request to `authenticationRequired` |
| 23 | **Guest-agent reachability** — counts running VMs via the PID-file layer; the authoritative vsock probe stays in `spook remote health <vm>` to keep doctor hermetic |

Run `spook doctor --strict` to verify every automatable row. The strict lane exits non-zero if any required item reports a `✗`; manual (`?`) and doctor-only (`⚠`) rows are informational. A non-zero exit means the deployment is **not hardened** — fail the change.

---

## 2. The minimum-safe environment

Drop this into `/etc/launchd/spooktacular.env` and `launchctl setenv` it:

```bash
# ─── TLS ─────────────────────────────────────────────────────────
export SPOOK_TLS_CERT_PATH=/etc/spooktacular/tls/server.crt
export SPOOK_TLS_KEY_PATH=/etc/spooktacular/tls/server.key
export SPOOK_TLS_CA_PATH=/etc/spooktacular/tls/ca.crt          # enables mTLS

# ─── API auth ────────────────────────────────────────────────────
# SPOOK_API_TOKEN is read from the Keychain when available;
# the env var is the fallback. Prefer the Keychain.
#
# security add-generic-password -s com.spooktacular.api \
#     -a spook-api -w "$(openssl rand -hex 48)" -U

# ─── Audit pipeline ──────────────────────────────────────────────
export SPOOK_AUDIT_FILE=/var/log/spooktacular/audit.jsonl
export SPOOK_AUDIT_IMMUTABLE_PATH=/var/log/spooktacular/audit.immutable.jsonl
export SPOOK_AUDIT_MERKLE=1
export SPOOK_AUDIT_SIGNING_KEY=/etc/spooktacular/secrets/merkle.key   # mode 0600

# S3 Object Lock WORM copy
export SPOOK_AUDIT_S3_BUCKET=acme-spooktacular-audit-prod-us-east-1
export SPOOK_AUDIT_S3_REGION=us-east-1
export SPOOK_AUDIT_S3_RETENTION_DAYS=2555  # 7-year retention (SOC 2 Type II)

# ─── RBAC & federated identity ───────────────────────────────────
export SPOOK_RBAC_CONFIG=/etc/spooktacular/rbac.json
export SPOOK_IDP_CONFIG=/etc/spooktacular/idps.json

# ─── Cross-region distributed lock ───────────────────────────────
export SPOOK_DYNAMO_TABLE=spooktacular-locks-prod
export SPOOK_DYNAMO_REGION=us-east-1

# ─── Tenancy ─────────────────────────────────────────────────────
export SPOOK_TENANCY_MODE=multi-tenant

# ─── Guest-agent tokens ──────────────────────────────────────────
# Injected into the VM at provision time, NEVER stored plaintext on
# the host — live in the Keychain and are copied into the guest via
# an ephemeral shared-folder file that's unlinked after first read.

# ─── AWS creds (for DynamoDB + S3) ───────────────────────────────
# Use an EC2 instance profile / IAM role where possible. If you
# must use static keys, store them in the Keychain and shell them
# out with `security find-generic-password -w`.
# export AWS_ACCESS_KEY_ID=...
# export AWS_SECRET_ACCESS_KEY=...
```

Do **not** set:

- `SPOOK_INSECURE_CONTROLLER=1` — disables mTLS check in the controller
- `SPOOK_TLS_MIN_VERSION=1.2` — env was removed in the security hardening batch; if you see this documented anywhere, it is out of date

---

## 3. Anti-footgun patterns

### 3.1 "Just get it running" shortcuts that actively remove security

| Shortcut | Why it's dangerous | The correct path |
|----------|-------------------|------------------|
| `spook serve --insecure` | Disables the TLS-required gate in production | Use `spook serve` with `SPOOK_TLS_*` set |
| `SPOOK_INSECURE_CONTROLLER=1` in a unit file | Controller accepts non-mTLS callers — token becomes the only auth | Only use on an engineer's laptop |
| Running without `SPOOK_AUDIT_FILE` | Audit goes to OSLog only; log rotation can evict evidence | Always set the JSONL path |
| Running without `SPOOK_AUDIT_IMMUTABLE_PATH` | The JSONL file is editable by anyone with `write` | Set the immutable-path, the kernel will enforce append-only |
| Running `SPOOK_AUDIT_MERKLE=1` without `SPOOK_AUDIT_SIGNING_KEY` | **Hard error** at startup — factory refuses to build with an ephemeral key. Good — leave the guard in place |
| Storing `AWS_SECRET_ACCESS_KEY` in a plaintext unit file | Credentials leak in `ps` output, backup archives, crash dumps | Keychain or instance profile |
| `chmod 644 merkle.key` | The loader refuses to start — it checks permissions before reading | `chmod 600`; if you need a second operator to read, add them as a Keychain ACL, don't loosen posix bits |
| Copy-pasting an OIDC IdP config without `staticJWKSPath` or `jwksURLOverride` in a regulated environment | Verifier fetches JWKS over the internet, vulnerable to on-path attack | Always pin — see § 3.2 |

### 3.2 Pinning OIDC JWKS

For air-gapped or high-compliance environments, set `staticJWKSPath` in every OIDC provider config:

```json
{
  "providers": [
    {
      "type": "oidc",
      "issuerURL": "https://auth.example.com",
      "clientID": "spooktacular-prod",
      "audience": "spooktacular-prod",
      "staticJWKSPath": "/etc/spooktacular/jwks/auth.example.com.json",
      "groupRoleMapping": {"sre": ["platform-admin"], "auditors": ["security-admin"]}
    }
  ]
}
```

Rotate the pinned JWKS by running the IdP's key-rotation ceremony, landing the new JWKS JSON into config management, and re-reading it — no restart required after the TTL expires. A `jwksURLOverride` is a middle-ground option when you need runtime freshness but still want all JWKS fetches to hit a mirror inside your perimeter.

### 3.3 Multi-tenant break-glass

Break-glass shell is disabled by default in multi-tenant mode. To enable for a specific tenant:

```jsonc
// /etc/spooktacular/tenants.json
[
  {
    "id": "red",
    "name": "Red Team",
    "hostPools": ["red-pool"],
    "breakGlassAllowed": true        // ⚠ this tenant can open shells in their VMs
  },
  {
    "id": "blue",
    "name": "Blue Team",
    "hostPools": ["blue-pool"]
    // breakGlassAllowed defaults to false — even a security-admin
    // with break-glass:invoke cannot open a shell in blue's VMs
  }
]
```

The permission check is `breakGlassAllowed (tenant) AND break-glass:invoke (role)`. Neither is enough on its own.

### 3.4 Lock-backend sanity

The distributed-lock factory logs the chosen backend at startup:

```
Distributed lock backend: DynamoDB(table=spooktacular-locks-prod, region=us-east-1)
```

If the line reads `File(dir=…)` in a multi-host fleet, stop the host and fix the config — file locks do not coordinate across hosts. DynamoDB with the wrong creds fails closed; if the line doesn't appear at all, `spook serve` failed to start.

---

## 4. Reference LaunchDaemon plist

`/Library/LaunchDaemons/com.spooktacular.serve.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.spooktacular.serve</string>

    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/spook</string>
        <string>serve</string>
        <!-- no --insecure, no --host 0.0.0.0 without firewall -->
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <key>EnvironmentVariables</key>
    <dict>
        <key>SPOOK_TLS_CERT_PATH</key>
        <string>/etc/spooktacular/tls/server.crt</string>
        <key>SPOOK_TLS_KEY_PATH</key>
        <string>/etc/spooktacular/tls/server.key</string>
        <key>SPOOK_TLS_CA_PATH</key>
        <string>/etc/spooktacular/tls/ca.crt</string>

        <key>SPOOK_AUDIT_FILE</key>
        <string>/var/log/spooktacular/audit.jsonl</string>
        <key>SPOOK_AUDIT_IMMUTABLE_PATH</key>
        <string>/var/log/spooktacular/audit.immutable.jsonl</string>
        <key>SPOOK_AUDIT_MERKLE</key>
        <string>1</string>
        <key>SPOOK_AUDIT_SIGNING_KEY</key>
        <string>/etc/spooktacular/secrets/merkle.key</string>

        <key>SPOOK_AUDIT_S3_BUCKET</key>
        <string>acme-spooktacular-audit-prod-us-east-1</string>
        <key>SPOOK_AUDIT_S3_REGION</key>
        <string>us-east-1</string>
        <key>SPOOK_AUDIT_S3_RETENTION_DAYS</key>
        <string>2555</string>

        <key>SPOOK_RBAC_CONFIG</key>
        <string>/etc/spooktacular/rbac.json</string>
        <key>SPOOK_IDP_CONFIG</key>
        <string>/etc/spooktacular/idps.json</string>

        <key>SPOOK_DYNAMO_TABLE</key>
        <string>spooktacular-locks-prod</string>
        <key>SPOOK_DYNAMO_REGION</key>
        <string>us-east-1</string>

        <key>SPOOK_TENANCY_MODE</key>
        <string>multi-tenant</string>
    </dict>

    <key>UserName</key>
    <string>spooktacular</string>
    <key>GroupName</key>
    <string>spooktacular</string>

    <key>StandardOutPath</key>
    <string>/var/log/spooktacular/serve.stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/spooktacular/serve.stderr.log</string>
</dict>
</plist>
```

Load:

```bash
sudo launchctl bootstrap system /Library/LaunchDaemons/com.spooktacular.serve.plist
sudo launchctl enable system/com.spooktacular.serve
sudo launchctl kickstart -k system/com.spooktacular.serve
```

---

## 5. Verification (proving it's live)

Run these three commands. The output is what an auditor wants to see.

### 5.1 TLS 1.3 + mTLS

```bash
openssl s_client -connect localhost:8484 -tls1_2 </dev/null
# Expect: handshake failure (server floors at 1.3)

openssl s_client -connect localhost:8484 -tls1_3 </dev/null \
    -cert client.crt -key client.key -CAfile /etc/spooktacular/tls/ca.crt
# Expect: Verify return code: 0 (ok), then you can issue GET /health
```

### 5.2 Audit chain — all four tiers present

```bash
# Tier 1: OSLog
log stream --predicate 'subsystem == "com.spooktacular"' --level info

# Tier 2: JSONL file
tail -f /var/log/spooktacular/audit.jsonl | jq .

# Tier 3: Append-only enforced by kernel
ls -lO /var/log/spooktacular/audit.immutable.jsonl
# Expect: flags include "uappnd"

echo "tampering" >> /var/log/spooktacular/audit.immutable.jsonl
# Expect: operation not permitted, errno EPERM — even for root
#         without explicit `chflags nouappnd` first

# Tier 4: S3 Object Lock
aws s3api get-object-lock-configuration --bucket $SPOOK_AUDIT_S3_BUCKET
# Expect: ObjectLockEnabled=Enabled, Mode=COMPLIANCE, Days=2555
```

### 5.3 RBAC deny-by-default

```bash
# Un-assigned actor tries to list VMs
curl --cacert ca.crt --cert client-ciuser.crt --key client-ciuser.key \
    -H "Authorization: Bearer $UNASSIGNED_TOKEN" \
    https://spook-01:8484/v1/vms
# Expect: {"error":"Forbidden. Your role does not have permission: vm:list"}
#         403
```

If any of these fails, the deployment is **not** hardened — stop traffic.

---

## 6. Rotation & drills

| Control | Cadence | Procedure |
|---------|---------|-----------|
| TLS server cert | 90 days | Replace `server.crt`/`server.key` on disk; file watcher hot-reloads with TLS 1.3 preserved |
| TLS client certs (controller/CI) | 180 days | Rotate via CA; old cert expires automatically |
| API bearer token | 180 days | `security delete-generic-password -s com.spooktacular.api -a spook-api`; re-add new |
| Guest-agent tokens | 90 days | Re-provision affected VMs with new token |
| Merkle signing key | 365 days or on suspected compromise | Write new file at `SPOOK_AUDIT_SIGNING_KEY`, restart; publish new public key to long-lived verifiers |
| OIDC JWKS (pinned) | On IdP rotation | Replace `staticJWKSPath` file, verifier picks up on next TTL |
| S3 Object Lock retention | Never shortens in Compliance mode | Write once; audit retention is contractual |

### Incident drill — quarterly

Simulate these in non-prod once a quarter; measure time-to-detect + time-to-remediate:

1. **Leaked break-glass token** — revoke the role assignment via `POST /v1/roles/revoke`, then rotate the token. Audit trail should show every break-glass use in the prior week.
2. **Compromised Mac host** — cordon via K8s (or removal from DynamoDB lock), stop scheduling, rotate all its secrets from Keychain, re-image.
3. **Merkle key compromise** — rotate, then verify that pre-rotation tree heads are flagged as "signed with revoked key" in the verifier.
4. **S3 Object Lock bucket misconfigured** — prove the alerting (`SpooktacularAPIErrorRateHigh` + audit-sink logs) catches silent failure within 10 minutes.

Every drill produces a report linked from the `THREAT_MODEL.md` §9 checklist.

---

## 7. When to deviate

Nothing in this doc is a suggestion — every item is a required control for regulated production. If your deployment legitimately needs to relax one (e.g., single-host homelab, no internet), document the exception in your change-management system with:

- Which control is relaxed
- Why (business justification, not technical convenience)
- What compensating control replaces it
- Expiry date for the exception

Do **not** silently omit controls. A one-line note in a ticket today saves two days of post-incident archaeology later.
