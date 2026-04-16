# Disaster Recovery

This document is the operational playbook for recovering a
Spooktacular fleet from partial or total loss. It assumes the
standard enterprise topology: a control plane (controller + API
server) in one AWS region plus Mac hosts running on EC2 Mac
Dedicated Hosts, with audit and state replicated to AWS durable
storage.

## Recovery objectives

| Tier | What fails | RTO | RPO |
|------|------------|-----|-----|
| **Single Mac host** | One EC2 Mac instance | ≤ 5 minutes | 0 (VMs ephemeral) |
| **Controller pod** | Kubernetes controller | ≤ 1 minute (leader election) | 0 (K8s CRDs are the source of truth) |
| **Region outage** | Entire AWS region down | ≤ 30 minutes | ≤ 5 minutes for audit; VMs re-provision on failover region |

## What to back up

### 1. Audit trail

Configure both local and remote audit:

```
SPOOK_AUDIT_FILE=/var/log/spooktacular/audit.jsonl
SPOOK_AUDIT_IMMUTABLE_PATH=/var/log/spooktacular/audit-immutable.jsonl
SPOOK_AUDIT_MERKLE=1
SPOOK_AUDIT_SIGNING_KEY=/var/lib/spooktacular/merkle-signing.key
SPOOK_AUDIT_S3_BUCKET=acme-spooktacular-audit
SPOOK_AUDIT_S3_REGION=us-east-1
SPOOK_AUDIT_S3_RETENTION_DAYS=2555
SPOOK_AUDIT_S3_PREFIX=audit/prod/
```

Enable **Cross-Region Replication** on the audit bucket so a
region outage doesn't lose the tail; enable **Object Lock** in
Compliance mode so even AWS support can't delete records early.
The Merkle signing key should be replicated to the DR region via
AWS Secrets Manager cross-region replication (replace the on-disk
file with a Secrets Manager hydration step on pod start).

### 2. Merkle signing key

Without the signing key, a restored audit log can be read but not
verified — tree heads won't match. Back it up to two places:

- **AWS Secrets Manager** (with automatic cross-region
  replication) for programmatic restore
- **Sealed envelope** in a physical vault for break-glass

The key file is a raw 32-byte Ed25519 private key; any binary
backup tool handles it. Rotate by stopping the controller and
replacing the file — the next tree head starts a new signature
chain, and the old chain remains verifiable with the old key.

### 3. Distributed lock state

- **Kubernetes leases**: no backup needed; they auto-recreate on
  controller restart.
- **DynamoDB leases** (cross-region): enable **Point-in-Time
  Recovery** on the DynamoDB table. Enable **Global Tables** to
  replicate to the DR region — a lock held in us-east-1 becomes
  visible in eu-west-1 within seconds.

### 4. VM images (IPSW / OCI)

Base VM images live in `~/.spooktacular/images/` on each Mac.
Ephemeral runner clones don't need backup — they're recreated
from base on boot. For bases:

- Sync `~/.spooktacular/images/` to S3 nightly via `aws s3 sync`.
- Store SHA-256 checksums alongside so integrity can be verified
  on restore.

### 5. TLS certificates + keys

- **Controller client cert**: managed by cert-manager via the
  Helm chart's Certificate resources (see
  `deploy/kubernetes/helm/spooktacular/templates/certificates.yaml`).
  Backed up as part of the cluster etcd snapshot.
- **Mac host server certs**: place on each host at
  `/etc/spooktacular/tls/`. Sync to AWS Secrets Manager.

### 6. Runner tokens + IdP config

- **GitHub runner PATs**: stored in Kubernetes Secrets referenced
  by `RunnerPool.ci.github.secretRef`. Backed up with etcd.
- **OIDC/SAML config**: stored in `SPOOK_IDP_CONFIG` JSON file.
  Back up alongside Helm values.

## Recovery procedures

### Single Mac host loss

1. Terminate the failed instance.
2. Re-launch an EC2 Mac Dedicated Host (note the 24-hour minimum
   allocation — plan accordingly).
3. Run the bootstrap script from `deploy/ec2-mac/bootstrap.sh`
   via SSM Run Command.
4. The controller notices the new host via the
   `spooktacular.app/role=mac-host` node label and schedules
   runner pool members onto it.
5. No data loss — ephemeral runners rebuild from base on first
   boot.

### Controller pod loss

Kubernetes handles this automatically: the replica count
restores, leader election picks a winner, and reconciliation
resumes from the CRD status subresource. No manual steps.

### Region outage

1. Update your DNS/ALB to point at the DR region's control plane
   endpoint. If the control plane is deployed with a global
   Route 53 failover record, this is automatic.
2. Confirm `DynamoDBDistributedLock` is operational in the DR
   region — Global Tables replication should already have the
   table state.
3. Confirm audit-bucket CRR has converged (check Last Replicated
   Time in the S3 console).
4. Mac hosts in the DR region re-register with the DR control
   plane. Runner pools re-provision from replicated base images.
5. Once the source region recovers, stop writes to it until you've
   reconciled audit state (both regions will have partial tails
   that need merging).

## Restoring from backup

### Audit trail

```bash
# Restore local JSONL tail
aws s3 cp s3://acme-spooktacular-audit/audit/prod/ \
  /var/log/spooktacular/ --recursive

# Verify Merkle tree against signed tree heads
spook audit verify \
  --signing-key /var/lib/spooktacular/merkle-signing.key \
  --tree-heads /var/log/spooktacular/tree-heads.jsonl
```

### Merkle signing key

```bash
# Pull from Secrets Manager
aws secretsmanager get-secret-value \
  --secret-id spooktacular/merkle-signing-key \
  --query SecretBinary --output text \
  | base64 -d > /var/lib/spooktacular/merkle-signing.key
chmod 600 /var/lib/spooktacular/merkle-signing.key
```

### VM base images

```bash
# Pull the base image cache from S3
aws s3 sync s3://acme-spooktacular-base-images/ \
  ~/.spooktacular/images/
# Verify checksums before first use
cd ~/.spooktacular/images
shasum -a 256 -c checksums.txt
```

## Testing recovery

Run a DR game day quarterly:

1. Pick a non-production cluster.
2. Delete the controller pod, confirm recovery within 60 s.
3. Terminate a Mac host, confirm runner pool reschedules.
4. Simulate a region failure by blocking the primary region's
   DynamoDB endpoint; confirm leases fail over to the DR region.
5. Test audit verification from S3-restored state.

Document RTO/RPO measurements; aim to tighten them each quarter.

## What's *not* covered

- **Apple EULA 2B(iii)**: running more than 2 VMs per Mac host is
  a legal constraint, not a DR constraint. Capacity planning must
  keep this in mind.
- **Cross-cloud failover**: Spooktacular targets AWS EC2 Mac
  explicitly. Cross-cloud (e.g., AWS → Scaleway Apple Silicon)
  requires additional plumbing outside this document's scope.
