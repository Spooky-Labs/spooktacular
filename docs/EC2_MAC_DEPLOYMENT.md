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

### Operator-side IAM

Beyond the instance-level policy above, running the Terraform module in `deploy/ec2-mac/terraform` with `enable_license_manager = true` and `enable_asg = true` requires these additional permissions on the operator's deploy principal:

| Service | Actions | Why |
|---------|---------|-----|
| `autoscaling` | `Create*`, `Update*`, `Delete*`, `PutLifecycleHook`, `CompleteLifecycleAction` | Manage the ASG + drain hook |
| `license-manager` | `CreateLicenseConfiguration`, `UpdateLicenseConfiguration`, `DeleteLicenseConfiguration` | Enforce Apple EULA host cap |
| `resource-groups` | `CreateGroup`, `UpdateGroup`, `DeleteGroup` | Host Resource Group for auto-allocation |
| `ssm` | `CreateDocument`, `UpdateDocument`, `CreateAssociation`, `StartAutomationExecution` | Install + drain runbooks |
| `events` | `PutRule`, `PutTargets`, `DeleteRule` | EventBridge → SSM Automation on terminate |
| `cloudwatch` | `PutMetricAlarm`, `DeleteAlarms` | Fleet health alarms |
| `sns` | `CreateTopic`, `Subscribe`, `DeleteTopic` | Alert + lifecycle notification topics |
| `iam` | `CreateRole`, `PutRolePolicy`, `AttachRolePolicy`, `PassRole` | Roles for the ASG, EventBridge, and SSM Automation |

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

## 6. Dedicated-Host → Kubernetes-Node mapping

Each EC2 Mac Dedicated Host surfaces in Kubernetes as exactly **one** Node. The kubelet runs on the EC2 Mac instance itself; the two VM slots are managed as Spooktacular `MacOSVM` custom resources scheduled onto that Node by the controller.

Label every Mac Node with this canonical set so the controller's scheduler and the fair-share scheduler (§7) can filter correctly:

| Label | Value | Purpose |
|-------|-------|---------|
| `spooktacular.app/role` | `mac-host` | Identifies the Node as a Spooktacular Mac host |
| `spooktacular.app/capacity` | `2` | Apple-EULA kernel cap — never more than 2 VMs per host |
| `topology.kubernetes.io/zone` | `<az>` | Matches the Dedicated Host's AZ (e.g., `us-east-1a`) |
| `topology.kubernetes.io/region` | `<region>` | AWS region |
| `node.kubernetes.io/instance-type` | `mac2.metal` | Kubelet auto-populates this from IMDS |

### kubeadm join example

Run this on the EC2 Mac after `bootstrap.sh` finishes, before any VMs start:

```bash
sudo kubeadm join \
  --token "${KUBEADM_TOKEN}" \
  --discovery-token-ca-cert-hash "sha256:${CA_HASH}" \
  --node-name "$(hostname -s)" \
  "${CONTROL_PLANE_ENDPOINT}:6443" \
  --node-labels "spooktacular.app/role=mac-host,spooktacular.app/capacity=2,topology.kubernetes.io/zone=$(curl -sS -H 'X-aws-ec2-metadata-token: $(curl -sS -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 300" http://169.254.169.254/latest/api/token)' http://169.254.169.254/latest/meta-data/placement/availability-zone)"
```

Verify the controller sees the Node labels:

```bash
kubectl get nodes -l spooktacular.app/role=mac-host \
  -o custom-columns=NAME:.metadata.name,ZONE:.metadata.labels.topology\\.kubernetes\\.io/zone,CAPACITY:.metadata.labels.spooktacular\\.app/capacity
```

The controller's `RunnerPoolReconciler` filters Nodes on the `spooktacular.app/role=mac-host` label before placing `MacOSVM` objects. If a Node is cordoned (`kubectl cordon`), the reconciler skips it and any in-flight VM requests for that Node are re-queued to another host.

## 7. 24-hour minimum allocation + drill cadence

EC2 Mac dedicated hosts enforce a 24-hour minimum allocation — the single biggest operational constraint of the platform. Spooktacular's `spook serve` doesn't fight this — but it DOES need a graceful drain path so hosts can be released when their 24h window is up.

### The constraint

AWS allocates Dedicated Hosts in 24-hour increments. Once allocated, you are billed for the full 24-hour window even if you:

- terminate the instance after 5 minutes,
- release the host immediately,
- put the host into `available` state without any running instances.

You cannot scale **down** a Mac fleet faster than 24 hours after the last host allocation.

### Implications for auto-scaling

The ASG's `termination_policies = ["OldestInstance"]` and the `drain-on-terminate` lifecycle hook in `lifecycle.tf` are both 24-hour-aware in a specific way: the ASG can scale up at any time, but the drain hook is the **only** way to get a clean host release. Scaling down before the 24h minimum just destroys an instance — you still pay for the host.

The controller should therefore:

1. Never scale **below** `license_count × 0.5` to avoid a 24h trough in which you lack capacity to re-scale.
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

## 8. Tenant-aware fair scheduling

On fleets where multiple business units share the same Spooktacular deployment, the default reconciler scales each runner pool independently — the first pool to ask for a VM wins. Under heavy load that produces "one tenant took everything" starvation.

`spook-controller` activates weighted max-min fair-share scheduling when **both** environment variables are set:

- `SPOOK_SCHEDULER_POLICY` — path to a JSON policy file
- `SPOOK_FLEET_CAPACITY` — integer total of VM slots across the fleet (typically `hostCount * 2` for Apple Silicon's 2-VM kernel limit)

Either unset → the reconciler falls through to independent per-pool scaling (the documented single-team posture).

### Policy file format

`/etc/spooktacular/scheduler.json`:

```json
[
  {"tenant": "platform", "weight": 3, "minGuaranteed": 4},
  {"tenant": "mobile",   "weight": 2, "minGuaranteed": 2, "maxCap": 20},
  {"tenant": "data",     "weight": 1, "minGuaranteed": 1}
]
```

Each entry:

- `tenant` — matches the `spooktacular.app/tenant` label on a `RunnerPool` CRD.
- `weight` — integer share used when demand exceeds capacity. `3:2:1` gives platform 3× mobile's share, 6× data's.
- `minGuaranteed` — minimum slots this tenant always gets (even under pressure). Prevents starvation of critical tenants.
- `maxCap` — optional hard ceiling; a tenant that demands more is capped here even if the fleet has room.

### Controller env vars

Add to `spook-controller`'s Deployment spec:

```yaml
env:
  - name: SPOOK_SCHEDULER_POLICY
    value: /etc/spooktacular/scheduler.json
  - name: SPOOK_FLEET_CAPACITY
    value: "40"   # 20 EC2 Mac hosts × 2 VMs each
```

At startup the controller logs:

```
RunnerPoolReconciler starting
Fair-share scheduler active: 3 policies, fleet capacity 40
```

During reconciliation, pools whose tenant is under pressure see their effective `maxRunners` clamped with a log line:

```
Fair-share: pool 'mobile-android' maxRunners clamped 30 → 12
```

The pool's own `minRunners` floor is always honored — the scheduler ensures the sum of all tenants' minimums fits in fleet capacity, so fair-share only ever reduces max, never min.

### Properties

- **Deterministic** — same inputs → same outputs, no wall-clock dependence.
- **Work-conserving** — never leaves capacity idle when any tenant has unmet demand.
- **Monotone** — adding capacity never reduces anyone's allocation; adding demand never reduces anyone else's.
- **No starvation** — `minGuaranteed` + the max-min algorithm mean even the lowest-weight tenant gets their floor.

16 tests in `FairSchedulerTests` pin the algorithm: weighted splits, minimums, caps, pool-level proportional breakdown, determinism, work-conservation, and the "sum never exceeds capacity" invariant across a sweep of capacities.

## Common pitfalls

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Refusing to start: production deployments require an audit sink.` | Operator set `SPOOK_TENANCY_MODE=multi-tenant` without any `SPOOK_AUDIT_*` | Add at minimum `SPOOK_AUDIT_FILE`; for SOC 2 add the full chain |
| `Distributed lock backend: File(dir=...)` in startup log | `SPOOK_DYNAMO_TABLE` unset on a multi-host fleet | Set it, restart; verify the startup log now says `DynamoDB(...)` |
| HTTP 500s with `"Internal error. Correlation ID: abc-123"` | Normal operation — the real error is in server logs | `log show --predicate 'subsystem == "com.spooktacular" AND category == "http-api"' --last 10m | grep abc-123` |
| S3 PutObject returns 403 | Instance role lacks `s3:PutObjectRetention` | Add to IAM policy (§1), wait 60s for IAM propagation |
| DynamoDB acquire hangs | Global Table replication lag | Verify replica regions match `SPOOK_DYNAMO_REGION`; prefer writing to the local-region endpoint |
