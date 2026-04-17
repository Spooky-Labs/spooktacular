# EC2 Mac Deployment Profile

**Audience:** Fortune-20 operators running Spooktacular on AWS EC2 Mac dedicated hosts for CI/CD, MDM, VDI, or agentic workloads.
**Precondition:** a dedicated host / Host Resource Group allocation with Apple Silicon `mac2.*.metal` instances. This doc assumes you already have the AWS side provisioned; it covers the Spooktacular configuration.

The rest of this doc is:

1. IAM policy for the EC2 instance role
2. Infrastructure provisioning (DynamoDB + S3 Object Lock)
3. Bootstrap script run by SSM at first boot
4. LaunchDaemon plist with the full audit chain + DynamoDB lock
5. `spook doctor --strict` verification
6. Drill cadence for the 24-hour minimum allocation compliance

Every env var referenced here is documented in [`DEPLOYMENT_HARDENING.md`](DEPLOYMENT_HARDENING.md). This doc is the EC2-specific concrete instance of that generic plan.

## 1. IAM policy

The EC2 Mac instance needs three AWS capabilities: DynamoDB (distributed locks), S3 Object Lock (WORM audit), and — if you use Secrets Manager instead of `security add-generic-password` — secret retrieval.

Minimal policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DynamoDBLockTable",
      "Effect": "Allow",
      "Action": [
        "dynamodb:PutItem",
        "dynamodb:GetItem",
        "dynamodb:DeleteItem",
        "dynamodb:UpdateItem"
      ],
      "Resource": "arn:aws:dynamodb:*:*:table/spooktacular-locks-prod"
    },
    {
      "Sid": "S3ObjectLockAuditBucket",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:PutObjectRetention"
      ],
      "Resource": "arn:aws:s3:::acme-spooktacular-audit-prod/*"
    },
    {
      "Sid": "CloudWatchMetrics",
      "Effect": "Allow",
      "Action": ["cloudwatch:PutMetricData"],
      "Resource": "*",
      "Condition": {
        "StringEquals": { "cloudwatch:namespace": "Spooktacular" }
      }
    }
  ]
}
```

Attach to an instance profile and assign to the EC2 Mac's `IamInstanceProfile`. Spooktacular's hand-rolled SigV4 picks up the credentials automatically via IMDSv2 — no `aws configure` needed.

## 2. AWS infrastructure

### DynamoDB Global Table

```bash
aws dynamodb create-table \
  --table-name spooktacular-locks-prod \
  --attribute-definitions AttributeName=name,AttributeType=S \
  --key-schema AttributeName=name,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1

# Promote to Global Table across the regions your fleet spans.
aws dynamodb update-table --table-name spooktacular-locks-prod \
  --replica-updates 'Create={RegionName=eu-west-1}' \
                    'Create={RegionName=ap-northeast-1}' \
  --region us-east-1
```

The table has a single partition key (`name`) and a TTL attribute (`expiresAt`) — `DynamoDBDistributedLock` manages both.

### S3 Object Lock bucket (WORM audit)

```bash
aws s3api create-bucket \
  --bucket acme-spooktacular-audit-prod \
  --region us-east-1 \
  --object-lock-enabled-for-bucket

aws s3api put-object-lock-configuration \
  --bucket acme-spooktacular-audit-prod \
  --object-lock-configuration '{
    "ObjectLockEnabled": "Enabled",
    "Rule": {
      "DefaultRetention": {
        "Mode": "COMPLIANCE",
        "Days": 2555
      }
    }
  }'
```

**Compliance** mode means even the root AWS account can't shorten retention — the right posture for SOC 2 Type II audit. 2555 days = 7 years.

## 3. SSM bootstrap document

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

## 4. LaunchDaemon plist (EC2 Mac profile)

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
        <key>SPOOK_TLS_CERT_PATH</key><string>/etc/spooktacular/tls/server.crt</string>
        <key>SPOOK_TLS_KEY_PATH</key> <string>/etc/spooktacular/tls/server.key</string>
        <key>SPOOK_TLS_CA_PATH</key>  <string>/etc/spooktacular/tls/ca.crt</string>

        <!-- Tenancy + federated identity -->
        <key>SPOOK_TENANCY_MODE</key> <string>multi-tenant</string>
        <key>SPOOK_IDP_CONFIG</key>    <string>/etc/spooktacular/idps.json</string>

        <!-- RBAC defaults to ~/.spooktacular/rbac.json with
             atomic persistence across restarts. Override with
             SPOOK_RBAC_CONFIG=<path> to centralize. -->

        <!-- Audit chain: local → append-only → Merkle → S3 Object Lock -->
        <key>SPOOK_AUDIT_FILE</key>             <string>/var/log/spooktacular/audit.jsonl</string>
        <key>SPOOK_AUDIT_IMMUTABLE_PATH</key>   <string>/var/log/spooktacular/audit.immutable.jsonl</string>
        <key>SPOOK_AUDIT_MERKLE</key>           <string>1</string>
        <key>SPOOK_AUDIT_SIGNING_KEY</key>      <string>/etc/spooktacular/secrets/merkle.key</string>
        <key>SPOOK_AUDIT_S3_BUCKET</key>        <string>acme-spooktacular-audit-prod</string>
        <key>SPOOK_AUDIT_S3_REGION</key>        <string>us-east-1</string>
        <key>SPOOK_AUDIT_S3_RETENTION_DAYS</key><string>2555</string>

        <!-- Cross-region lock — DynamoDB Global Table -->
        <key>SPOOK_DYNAMO_TABLE</key>  <string>spooktacular-locks-prod</string>
        <key>SPOOK_DYNAMO_REGION</key> <string>us-east-1</string>

        <!-- Data-at-rest: EC2 Mac hosts are NOT laptops, so CUFUA
             would break pre-login LaunchDaemon reads. Explicit "none"
             documents the intent for auditors. -->
        <key>SPOOK_BUNDLE_PROTECTION</key><string>none</string>
    </dict>

    <key>UserName</key>  <string>spooktacular</string>
    <key>GroupName</key> <string>spooktacular</string>

    <key>StandardOutPath</key><string>/var/log/spooktacular/serve.stdout.log</string>
    <key>StandardErrorPath</key><string>/var/log/spooktacular/serve.stderr.log</string>
</dict>
</plist>
```

Note the absence of `--insecure` anywhere — the production preflight will refuse to start if any of TLS, RBAC, audit-sink, or mTLS are missing.

## 5. Verification

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
✓ SPOOK_API_TOKEN set
✓ Capacity: 0/2 VMs running

Production controls (--strict)
------------------------------
✓ mTLS CA: /etc/spooktacular/tls/ca.crt
✓ RBAC config: /Users/spooktacular/.spooktacular/rbac.json
✓ Federated IdP config: /etc/spooktacular/idps.json
✓ Audit JSONL: /var/log/spooktacular/audit.jsonl (writable)
✓ Append-only audit file: /var/log/spooktacular/audit.immutable.jsonl (UF_APPEND set)
✓ Merkle signing key: /etc/spooktacular/secrets/merkle.key (mode 0600)
✓ Distributed lock: DynamoDB (cross-region)
✓ Tenancy mode: multi-tenant
✓ Insecure-controller bypass is OFF
✓ Hardened Runtime + Team ID present on spook binary
✓ Bundle protection: 1 bundle(s) at None [overrideSettingsNone], inheritance verified
```

Every `✓` is a control an auditor can walk straight to. Any `✗` on a production host is a ship-blocker.

## 6. 24-hour minimum allocation + drill cadence

EC2 Mac dedicated hosts enforce a 24-hour minimum allocation. Spooktacular's `spook serve` doesn't fight this — but it DOES need a graceful drain path so hosts can be released when their 24h window is up.

### Drain sequence

```bash
# 1. Cordon this host in your controller (no new VMs)
kubectl cordon node-ec2-mac-01   # if using the K8s controller

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
- **Merkle key rotation**: replace `/etc/spooktacular/secrets/merkle.key`, verify signed-tree-head chain.
- **S3 Object Lock misconfiguration**: prove `SpooktacularAPIErrorRateHigh` alert fires within 10 minutes when S3 writes start 403'ing.

Report times + remediation to the `docs/THREAT_MODEL.md` §9 external-validation checklist.

## 7. Tenant-aware fair scheduling

On fleets where multiple business units share the same Spooktacular deployment, the default reconciler scales each runner pool independently — the first pool to ask for a VM wins. Under heavy load that produces "one tenant took everything" starvation.

Plug `FairScheduler` in to enforce weighted max-min fair-share allocation:

```swift
// Three BUs sharing an EC2 Mac fleet of 20 slots
let scheduler = FairScheduler(policies: [
    .init(tenant: TenantID("platform"), weight: 3, minGuaranteed: 4),
    .init(tenant: TenantID("mobile"),   weight: 2, minGuaranteed: 2),
    .init(tenant: TenantID("data"),     weight: 1, minGuaranteed: 1),
])

// Ask the scheduler how to split each reconciliation cycle
let alloc = scheduler.allocate(
    demand: [
        TenantID("platform"): 15,
        TenantID("mobile"):   10,
        TenantID("data"):      8,
    ],
    capacity: 20
)
// → platform: 10, mobile: 6, data: 4 — weighted + no starvation
```

Properties: deterministic, work-conserving, monotone. Tests in `FairSchedulerTests` pin the contract. Wiring into `RunnerPoolReconciler` is a one-call replacement for the current per-pool `min(...,max(...))` clamp.

## Common pitfalls

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Refusing to start: production deployments require an audit sink.` | Operator set `SPOOK_TENANCY_MODE=multi-tenant` without any `SPOOK_AUDIT_*` | Add at minimum `SPOOK_AUDIT_FILE`; for SOC 2 add the full chain |
| `Distributed lock backend: File(dir=...)` in startup log | `SPOOK_DYNAMO_TABLE` unset on a multi-host fleet | Set it, restart; verify the startup log now says `DynamoDB(...)` |
| HTTP 500s with `"Internal error. Correlation ID: abc-123"` | Normal operation — the real error is in server logs | `log show --predicate 'subsystem == "com.spooktacular" AND category == "http-api"' --last 10m | grep abc-123` |
| S3 PutObject returns 403 | Instance role lacks `s3:PutObjectRetention` | Add to IAM policy (§1), wait 60s for IAM propagation |
| DynamoDB acquire hangs | Global Table replication lag | Verify replica regions match `SPOOK_DYNAMO_REGION`; prefer writing to the local-region endpoint |
