# EC2 Mac Deployment Profile

**Audience:** Operators running Spooktacular on AWS EC2 Mac dedicated hosts for CI/CD, VDI, or agentic workloads.
**Precondition:** a dedicated host / Host Resource Group allocation with Apple Silicon `mac2.*.metal` instances. This doc assumes you already have the AWS side provisioned; it covers the Spooktacular configuration.

The rest of this doc is:

1. Bootstrap script run by SSM at first boot
2. LaunchDaemon plist
3. `spook doctor --strict` verification
4. Drill cadence for the 24-hour minimum allocation compliance
5. Tenant-aware fair scheduling (standalone algorithm, not yet wired to an orchestrator)

Every env var referenced here is documented in [`DEPLOYMENT_HARDENING.md`](DEPLOYMENT_HARDENING.md). This doc is the EC2-specific concrete instance of that generic plan.

## 1. SSM bootstrap document

Run this at first-boot via Systems Manager State Manager so every EC2 Mac instance lands in a known-good configuration.

```bash
#!/bin/bash
# /etc/spooktacular/bootstrap.sh — executed by ssm-user at first boot
set -euo pipefail

# Install spook (assumes an internal package mirror or S3 build
# artifact — replace this with your org's binary-distribution flow)
aws s3 cp s3://acme-releases/spooktacular/latest/spook /usr/local/bin/spook
chmod +x /usr/local/bin/spook

# Create the dedicated daemon user + storage
sysadminctl -addUser spooktacular -fullName "Spooktacular Daemon" -password "$(openssl rand -hex 32)"
mkdir -p /etc/spooktacular/tls /etc/spooktacular/secrets
mkdir -p /var/log/spooktacular

# mTLS material — retrieved from ACM Private CA or Secrets Manager
aws secretsmanager get-secret-value \
  --secret-id spooktacular/tls/server-cert \
  --query SecretString --output text > /etc/spooktacular/tls/server.crt
# (repeat for server.key, ca.crt)
chmod 600 /etc/spooktacular/tls/server.key

# API token in Keychain (daemon user's login keychain)
sudo -u spooktacular security add-generic-password \
  -s com.spooktacular.api \
  -a default \
  -w "$(aws secretsmanager get-secret-value \
       --secret-id spooktacular/api-token \
       --query SecretString --output text)" \
  -U

# Install the LaunchDaemon plist
cp /etc/spooktacular/com.spooktacular.serve.plist \
   /Library/LaunchDaemons/
launchctl bootstrap system /Library/LaunchDaemons/com.spooktacular.serve.plist

# Verify the fleet controls are live
sudo -u spooktacular /usr/local/bin/spook doctor --strict
```

## 2. LaunchDaemon plist (EC2 Mac profile)

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
    </array>

    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>

    <key>EnvironmentVariables</key>
    <dict>
        <!-- TLS + mTLS -->
        <key>SPOOKTACULAR_TLS_CERT_PATH</key><string>/etc/spooktacular/tls/server.crt</string>
        <key>SPOOKTACULAR_TLS_KEY_PATH</key> <string>/etc/spooktacular/tls/server.key</string>
        <key>SPOOKTACULAR_TLS_CA_PATH</key>  <string>/etc/spooktacular/tls/ca.crt</string>

        <!-- Tenancy -->
        <key>SPOOKTACULAR_TENANCY_MODE</key> <string>multi-tenant</string>

        <!-- RBAC defaults to ~/.spooktacular/rbac.json with
             atomic persistence across restarts. Override with
             SPOOKTACULAR_RBAC_CONFIG=<path> to centralize. -->

        <!-- Audit chain: local file → append-only kernel flag. -->
        <key>SPOOKTACULAR_AUDIT_FILE</key>            <string>/var/log/spooktacular/audit.jsonl</string>
        <key>SPOOKTACULAR_AUDIT_IMMUTABLE_PATH</key>  <string>/var/log/spooktacular/audit.immutable.jsonl</string>

        <!-- Distributed lock: file-backed over a shared mount.
             SPOOKTACULAR_LOCK_DIR defaults to
             ~/.spooktacular/locks; override to point at NFS for
             multi-host coordination. -->

        <!-- Data-at-rest: EC2 Mac hosts are NOT laptops, so CUFUA
             would break pre-login LaunchDaemon reads. Explicit "none"
             documents the intent for auditors. -->
        <key>SPOOKTACULAR_BUNDLE_PROTECTION</key><string>none</string>
    </dict>

    <key>UserName</key>  <string>spooktacular</string>
    <key>GroupName</key> <string>spooktacular</string>

    <key>StandardOutPath</key><string>/var/log/spooktacular/serve.stdout.log</string>
    <key>StandardErrorPath</key><string>/var/log/spooktacular/serve.stderr.log</string>
</dict>
</plist>
```

Note the absence of `--insecure` anywhere — the production preflight will refuse to start if any of TLS, RBAC, or the audit sink are missing.

## 3. Verification

After the SSM bootstrap completes, SSH to the instance and confirm:

```
$ sudo -u spooktacular /usr/local/bin/spook doctor --strict
Spooktacular Doctor
===================
✓ Apple Silicon (arm64)
✓ macOS 15.4.0 (minimum: 14.0)
✓ Virtualization.framework available
✓ Disk space: 234 GB free
✓ Base VM found: macos-15-base
✓ spook serve running (port 8484)
✓ TLS configured on port 8484
✓ SPOOKTACULAR_API_TOKEN set
✓ Capacity: 0/2 VMs running

Production controls (--strict)
------------------------------
✓ [01] TLS cert+key readable
✓ [02] mTLS CA: /etc/spooktacular/tls/ca.crt
✓ [03] TLS 1.3 floor enforced on port 8484
✓ [04] API bearer token present in Keychain
✓ [06] RBAC config readable: /Users/spooktacular/.spooktacular/rbac.json
✓ [09] Audit JSONL: /var/log/spooktacular/audit.jsonl (dir writable)
✓ [10] Append-only audit: /var/log/spooktacular/audit.immutable.jsonl (UF_APPEND set)
✓ [14] Tenancy mode: multi-tenant
✓ [15] Insecure — SPOOKTACULAR_INSECURE_CONTROLLER is not set
✓ [16] Hardened Runtime + Team ID present on spook binary
✓ [17] Code-signing timestamp present
```

Every `✓` is a control an auditor can walk straight to. Any `✗` on a production host is a ship-blocker.

## 4. 24-hour minimum allocation + drill cadence

EC2 Mac dedicated hosts enforce a 24-hour minimum allocation — the single biggest operational constraint of the platform. Spooktacular's `spook serve` doesn't fight this — but it DOES need a graceful drain path so hosts can be released when their 24h window is up.

### The constraint

AWS allocates Dedicated Hosts in 24-hour increments. Once allocated, you are billed for the full 24-hour window even if you:

- terminate the instance after 5 minutes,
- release the host immediately,
- put the host into `available` state without any running instances.

You cannot scale **down** a Mac fleet faster than 24 hours after the last host allocation.

### Implications for auto-scaling

If you drive fleet size from an Auto Scaling Group, terminate on the *oldest* instance first and gate scale-down behind a drain hook — scaling down before the 24h minimum just destroys an instance, you still pay for the host.

The scaling policy should therefore:

1. Never scale below the number of hosts needed to cover your license count's floor, to avoid a 24h trough in which you lack capacity to re-scale.
2. Prefer reuse of in-service hosts (VM scrub-and-reset) over host replacement.
3. Batch scale-down events to host-release cadence — daily at a known low-traffic window, not reactively to every queue drop.

### Cost model example

A single `mac2.metal` Dedicated Host runs ~$1.08/hour on-demand. Concrete impact of the 24h rule at three scales:

| Fleet pattern | Naive cost (no 24h awareness) | Actual cost (24h enforced) | Waste |
|---------------|-------------------------------|----------------------------|-------|
| 1 host, 2h workload | $2.16 | $25.92 | $23.76 / run (92%) |
| 10 hosts, steady 8h/day | $86.40/day | $259.20/day | $172.80/day (66%) |
| 10 hosts, 24h-aware batching | $86.40/day | $86.40/day | $0 |

With Savings Plans (up to 44% off), the "actual" column drops proportionally, but the **waste ratio** stays the same until you align workload duration with 24h windows.

### Drain sequence

```bash
# 1. Drain this host (stop accepting new VMs) — see bootstrap.sh --drain
sudo bash /path/to/bootstrap.sh --drain

# 2. Stop all running VMs gracefully
for vm in $(spook list --running --format=names); do
    spook stop "$vm"
done

# 3. Wait for VM workloads to complete
spook list --running   # should be empty

# 4. Stop the service
sudo launchctl bootout system /Library/LaunchDaemons/com.spooktacular.serve.plist

# 5. Release the dedicated host
aws ec2 release-hosts --host-ids h-xxxxxxxxxxx
```

### Quarterly drills

Every quarter, rehearse each of these against a non-prod fleet and log the time-to-complete:

- **Break-glass token rotation**: revoke, rotate, verify every affected VM.
- **Compromised host**: cordon → drain → release → provision replacement from clean AMI.

## 5. Tenant-aware fair scheduling

On fleets where multiple business units share the same Spooktacular deployment and demand exceeds capacity, naive independent scaling per pool produces "one tenant took everything" starvation. `SpooktacularCore` ships `FairScheduler`, a weighted max-min allocator built for exactly this problem.

`FairScheduler` is not currently wired into a runtime orchestrator. It ships as a tested, standalone algorithm ready for the next runner-pool orchestrator to adopt.

### Policy shape

`FairScheduler` takes a `TenantSchedulingPolicy` per tenant:

```json
[
  {"tenant": "platform", "weight": 3, "minGuaranteed": 4},
  {"tenant": "mobile",   "weight": 2, "minGuaranteed": 2, "maxCap": 20},
  {"tenant": "data",     "weight": 1, "minGuaranteed": 1}
]
```

Each entry:

- `tenant` — the `TenantID` this policy applies to.
- `weight` — integer share used when demand exceeds capacity. `3:2:1` gives platform 3× mobile's share, 6× data's.
- `minGuaranteed` — minimum slots this tenant always gets (even under pressure). Prevents starvation of critical tenants.
- `maxCap` — optional hard ceiling; a tenant that demands more is capped here even if the fleet has room.

### Properties

- **Deterministic** — same inputs → same outputs, no wall-clock dependence.
- **Work-conserving** — never leaves capacity idle when any tenant has unmet demand.
- **Monotone** — adding capacity never reduces anyone's allocation; adding demand never reduces anyone else's.
- **No starvation** — `minGuaranteed` + the max-min algorithm mean even the lowest-weight tenant gets their floor.

`FairSchedulerTests` pins the algorithm: weighted splits, minimums, caps, pool-level proportional breakdown, determinism, work-conservation, and the "sum never exceeds capacity" invariant across a sweep of capacities.

## Common pitfalls

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Refusing to start: production deployments require an audit sink.` | Operator set `SPOOKTACULAR_TENANCY_MODE=multi-tenant` without any `SPOOKTACULAR_AUDIT_*` | Add at minimum `SPOOKTACULAR_AUDIT_FILE` |
| `Distributed lock backend: File(dir=...)` in startup log, but locks aren't visible across hosts | `SPOOKTACULAR_LOCK_DIR` points at a local (non-shared) directory on a multi-host fleet | Point it at a shared NFS mount, or coordinate lock-holder release manually until a cross-host backend ships |
| HTTP 500s with `"Internal error. Correlation ID: abc-123"` | Normal operation — the real error is in server logs | `log show --predicate 'subsystem == "com.spooktacular" AND category == "http-api"' --last 10m \| grep abc-123` |
