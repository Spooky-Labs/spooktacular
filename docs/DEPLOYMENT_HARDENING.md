# Spooktacular Hardened Deployment Guide

**Audience:** Operators deploying Spooktacular in a production environment.
**Goal:** Walk from empty host to a production-grade deployment without a single "we'll fix it later."
**Posture:** Fail-closed — if a required control is missing, the process refuses to start. No silent degradation.

The rest of this document is organized as:

1. **Pre-flight checklist** — stop here if any line is unchecked.
2. **The minimum-safe environment** — the exact env vars that flip every control on.
3. **Anti-footgun patterns** — known ways operators accidentally disable security, and how to avoid them.
4. **Reference `launchd` plist** — tested, copy-paste ready.
5. **Verification** — how to prove to an auditor that each control is live.
6. **Rotation & drills** — what to do on day-90, day-180, and on incident.

---

## 1. Pre-flight checklist

Every item is **required for production**. A cell marked "dev-only" means the code will accept it, but your change-control board should not.

The **Doctor** column indicates how `spook doctor --strict` surfaces each row — `Y` (fully automated) or `manual` (printed with a `?` marker because the CLI cannot introspect an external system, e.g. build-time dependency tooling). Every strict-mode output line is prefixed `[##]` with the item number below, so the table is a literal row-by-row projection of the command's output. Item numbers are **not** contiguous — 7, 8, 11, 12, 13, and 19 were controls for subsystems (federated SAML/OIDC login, Merkle-signed audit, S3 Object Lock, DynamoDB distributed locking) that have since been removed from the product; the remaining numbers were left as-is rather than renumbered, so this table and the CLI output stay a 1:1 match.

| # | Control | How to verify | Doctor (`spook doctor --strict`) |
|---|---------|---------------|----------------------------------|
| 1 | TLS certificate + key configured | `SPOOKTACULAR_TLS_CERT_PATH`, `SPOOKTACULAR_TLS_KEY_PATH` both set and readable by the daemon user | Y — env set + file readable |
| 2 | mTLS (client cert required) | `SPOOKTACULAR_TLS_CA_PATH` set and readable — server presents cert, client cert is required on every request | Y — `SPOOKTACULAR_TLS_CA_PATH` readable |
| 3 | TLS 1.3 floor | No explicit config needed — enforced in code, hot-reload preserves it | Y — TLS-1.3 handshake probed on port 8484 (warn when serve is offline) |
| 4 | API bearer token in Keychain | `security find-generic-password -a spook-api -s com.spooktacular.api` returns a value | Y — Keychain probe via `SecItemCopyMatching`; env-var fallback is flagged as warning |
| 5 | Guest-agent tokens present | `SPOOKTACULAR_AGENT_TOKEN` / `SPOOKTACULAR_AGENT_RUNNER_TOKEN` / `SPOOKTACULAR_AGENT_READONLY_TOKEN` set, or a Keychain entry at `com.spooktacular.agent` | Y — env presence OR Keychain entry |
| 6 | RBAC active | `SPOOKTACULAR_RBAC_CONFIG` points at a readable JSON file, or `SPOOKTACULAR_MACOS_GROUP_MAPPING` is set | Y — file readable OR group mapping set |
| 9 | Audit JSONL enabled | `SPOOKTACULAR_AUDIT_FILE` set, path is writable, tail the file to confirm records flow | Y — env set + parent directory writable |
| 10 | Append-only audit backing | `SPOOKTACULAR_AUDIT_IMMUTABLE_PATH` set; after first write, `ls -lO` shows `uappnd` on the file | Y — `stat(2)` on the path checks `UF_APPEND` |
| 14 | Tenancy mode set | `SPOOKTACULAR_TENANCY_MODE=multi-tenant` for any fleet with more than one team's workloads | Y — echoes the configured mode (defaults to `single-tenant`) |
| 15 | Insecure mode is OFF | `SPOOKTACULAR_INSECURE_CONTROLLER` is unset and `spook serve --insecure` is never in a unit file | Y — env var guard |
| 16 | Hardened Runtime + notarization | `codesign -d --verbose=4 /usr/local/bin/spook` shows `flags=0x10000(runtime)` and `TeamIdentifier` | Y — invokes `codesign -d --verbose=4` on `$ARGV[0]` |
| 17 | Code-signing timestamp | Same output shows `Signed Time=…` (from `--timestamp` in `build-app.sh`) | Y — same codesign output parsed for `Signed Time=` / `Timestamp=` |
| 18 | Only Apple SDKs in dependency tree | `swift package show-dependencies --format json` returns an empty `dependencies` array | manual — build-time; doctor prints `?` with the one-liner to run locally |

### Doctor-only probes (numbered ≥ 20)

`spook doctor --strict` also surfaces reviewer-flagged probes that aren't part of the numbered 1–18 sequence above but are easy failure modes in practice:

| Doctor # | What it probes |
|----------|----------------|
| 20 | **IAM binding store writability** — `SPOOKTACULAR_IAM_BINDINGS_CONFIG` path / parent directory can be opened for read+write; if not, `/v1/vms/:name/identity-token` returns empty bindings instead of minting |
| 21 | **Audit sink can-write probe** — opens `SPOOKTACULAR_AUDIT_FILE` for append (creating it if absent + permitted) so permissions mismatches surface at doctor time instead of on the first authentic request |
| 22 | **Signed-request verifier key material** — `SPOOKTACULAR_API_PUBLIC_KEYS_DIR` contains ≥ 1 `.pem` / `.pub` file; an empty directory silently degrades every signed request to `authenticationRequired` |
| 23 | **Guest-agent reachability** — counts running VMs via the PID-file layer as a proxy for reachability; always reports `pass` |

Run `spook doctor --strict` to verify every automatable row. The strict lane exits non-zero if any required item reports a `✗`; the manual (`?`) row is informational. A non-zero exit means the deployment is **not hardened** — fail the change.

---

## 2. The minimum-safe environment

Drop this into `/etc/launchd/spooktacular.env` and `launchctl setenv` it:

```bash
# ─── TLS ─────────────────────────────────────────────────────────
export SPOOKTACULAR_TLS_CERT_PATH=/etc/spooktacular/tls/server.crt
export SPOOKTACULAR_TLS_KEY_PATH=/etc/spooktacular/tls/server.key
export SPOOKTACULAR_TLS_CA_PATH=/etc/spooktacular/tls/ca.crt          # enables mTLS

# ─── API auth ────────────────────────────────────────────────────
# SPOOKTACULAR_API_TOKEN is read from the Keychain when available;
# the env var is the fallback. Prefer the Keychain.
#
# security add-generic-password -s com.spooktacular.api \
#     -a spook-api -w "$(openssl rand -hex 48)" -U

# ─── Audit pipeline ──────────────────────────────────────────────
export SPOOKTACULAR_AUDIT_FILE=/var/log/spooktacular/audit.jsonl
export SPOOKTACULAR_AUDIT_IMMUTABLE_PATH=/var/log/spooktacular/audit.immutable.jsonl

# ─── RBAC ─────────────────────────────────────────────────────────
export SPOOKTACULAR_RBAC_CONFIG=/etc/spooktacular/rbac.json

# ─── Tenancy ─────────────────────────────────────────────────────
export SPOOKTACULAR_TENANCY_MODE=multi-tenant

# ─── Workload identity-token bindings ────────────────────────────
export SPOOKTACULAR_IAM_BINDINGS_CONFIG=/etc/spooktacular/iam-bindings.json

# ─── Signed-request trust store ──────────────────────────────────
export SPOOKTACULAR_API_PUBLIC_KEYS_DIR=/etc/spooktacular/api-keys/

# ─── Guest-agent tokens ──────────────────────────────────────────
# Injected into the VM at provision time, NEVER stored plaintext on
# the host — live in the Keychain and are copied into the guest via
# an ephemeral shared-folder file that's unlinked after first read.
```

Do **not** set:

- `SPOOKTACULAR_INSECURE_CONTROLLER=1` — disables the mTLS-required check
- `SPOOKTACULAR_TLS_MIN_VERSION=1.2` — env was removed in the security hardening batch; if you see this documented anywhere, it is out of date

---

## 3. Anti-footgun patterns

### 3.1 "Just get it running" shortcuts that actively remove security

| Shortcut | Why it's dangerous | The correct path |
|----------|-------------------|------------------|
| `spook serve --insecure` | Disables the TLS-required gate in production | Use `spook serve` with `SPOOKTACULAR_TLS_*` set |
| `SPOOKTACULAR_INSECURE_CONTROLLER=1` in a unit file | Server accepts non-mTLS callers — token becomes the only auth | Only use on an engineer's laptop |
| Running without `SPOOKTACULAR_AUDIT_FILE` | Audit goes to OSLog only; log rotation can evict evidence | Always set the JSONL path |
| Running without `SPOOKTACULAR_AUDIT_IMMUTABLE_PATH` | The JSONL file is editable by anyone with `write` | Set the immutable-path, the kernel will enforce append-only |
| `chmod 644` on a Keychain-backed private key export | Undermines the point of Keychain-backed storage | Keep private key material in the Keychain; never export to disk in production |

### 3.2 Multi-tenant break-glass

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

### 3.3 Distributed lock backend

`DistributedLockFactory.makeFromEnvironment()` currently ships a single backend — `FileDistributedLock`, using `flock(2)` over `SPOOKTACULAR_LOCK_DIR` (defaults to `~/.spooktacular/locks`). It is suitable for a single host or a shared-NFS mount; it is **not** a cross-region coordination primitive. The chosen backend is logged at startup (`Distributed lock backend: File(dir=…)`) so operators can confirm the directory is on the shared filesystem they expect.

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
        <key>SPOOKTACULAR_TLS_CERT_PATH</key>
        <string>/etc/spooktacular/tls/server.crt</string>
        <key>SPOOKTACULAR_TLS_KEY_PATH</key>
        <string>/etc/spooktacular/tls/server.key</string>
        <key>SPOOKTACULAR_TLS_CA_PATH</key>
        <string>/etc/spooktacular/tls/ca.crt</string>

        <key>SPOOKTACULAR_AUDIT_FILE</key>
        <string>/var/log/spooktacular/audit.jsonl</string>
        <key>SPOOKTACULAR_AUDIT_IMMUTABLE_PATH</key>
        <string>/var/log/spooktacular/audit.immutable.jsonl</string>

        <key>SPOOKTACULAR_RBAC_CONFIG</key>
        <string>/etc/spooktacular/rbac.json</string>

        <key>SPOOKTACULAR_TENANCY_MODE</key>
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

Run these commands. The output is what an auditor wants to see.

### 5.1 TLS 1.3 + mTLS

```bash
openssl s_client -connect localhost:8484 -tls1_2 </dev/null
# Expect: handshake failure (server floors at 1.3)

openssl s_client -connect localhost:8484 -tls1_3 </dev/null \
    -cert client.crt -key client.key -CAfile /etc/spooktacular/tls/ca.crt
# Expect: Verify return code: 0 (ok), then you can issue GET /health
```

### 5.2 Audit chain

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
| TLS client certs (mTLS callers) | 180 days | Rotate via CA; old cert expires automatically |
| API bearer token | 180 days | `security delete-generic-password -s com.spooktacular.api -a spook-api`; re-add new |
| Guest-agent tokens | 90 days | Re-provision affected VMs with new token |

### Incident drill — quarterly

Simulate these in non-prod once a quarter; measure time-to-detect + time-to-remediate:

1. **Leaked break-glass token** — revoke the role assignment via `POST /v1/roles/revoke`, then rotate the token. Audit trail should show every break-glass use in the prior week.
2. **Compromised Mac host** — remove it from the fleet's dispatch target list, stop scheduling, rotate all its secrets from Keychain, re-image.

Every drill's findings should land in your own incident-tracking system; publish a summary internally so the next quarter's drill starts from a known baseline.

---

## 7. When to deviate

Nothing in this doc is a suggestion — every item is a required control for production. If your deployment legitimately needs to relax one (e.g., single-host homelab, no internet), document the exception in your change-management system with:

- Which control is relaxed
- Why (business justification, not technical convenience)
- What compensating control replaces it
- Expiry date for the exception

Do **not** silently omit controls. A one-line note in a ticket today saves two days of post-incident archaeology later.
