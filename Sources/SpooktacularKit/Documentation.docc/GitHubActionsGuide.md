# GitHub Actions Runners

Run self-hosted macOS GitHub Actions runners in Spooktacular VMs with ephemeral isolation and automatic scaling.

## Overview

Spooktacular turns every Apple Silicon Mac into a GitHub Actions
runner host that supports **2 concurrent runners** instead of 1.
Each runner runs inside an isolated macOS VM that can be destroyed
and recreated between jobs for a clean-room guarantee.

### Why Self-Hosted macOS Runners?

| Factor | GitHub-hosted | Self-hosted (bare metal) | Spooktacular |
|--------|--------------|------------------------|--------------|
| Cost (per runner/month) | ~$2,400 (macOS L) | ~$780 (EC2 Mac) | ~$390 (EC2 Mac, 2x) |
| Xcode version control | Limited | Full | Full |
| Hardware access (GPU, Neural Engine) | No | Yes (1 runner) | Yes (2 runners) |
| Clean environment per job | Yes | Manual | Yes (ephemeral VMs) |
| Queue time | Minutes | Seconds | Seconds |
| Scaling | Automatic | Manual | Automatic |

Spooktacular gives you the cost savings of self-hosted infrastructure
with the clean-environment guarantees of GitHub-hosted runners.

## Quick Start: One Mac, Two Runners

The fastest path from zero to two working GitHub Actions runners:

```bash
# 1. Install Spooktacular
brew install --cask spooktacular

# 2. Create two runner VMs
spook create runner-01 --from-ipsw latest \
    --cpu 4 --memory 8 --disk 64 \
    --user-data ~/github-runner-setup.sh \
    --provision disk-inject

spook create runner-02 --from-ipsw latest \
    --cpu 4 --memory 8 --disk 64 \
    --user-data ~/github-runner-setup.sh \
    --provision disk-inject

# 3. Start both runners headless
spook start runner-01 --headless
spook start runner-02 --headless
```

Where `github-runner-setup.sh` contains:

```bash
#!/bin/bash
set -euo pipefail

REPO="myorg/myrepo"
TOKEN="ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
LABELS="macos,arm64,xcode16"

# Download the runner
cd /Users/admin
mkdir -p actions-runner && cd actions-runner
curl -o actions-runner.tar.gz -L \
    "https://github.com/actions/runner/releases/download/v2.320.0/actions-runner-osx-arm64-2.320.0.tar.gz"
tar xzf actions-runner.tar.gz

# Register with GitHub
./config.sh --url "https://github.com/$REPO" \
    --token "$TOKEN" \
    --labels "$LABELS" \
    --name "$(hostname)" \
    --ephemeral \
    --unattended

# Install and start as a LaunchDaemon
./svc.sh install
./svc.sh start
```

## The --github-runner Template

Spooktacular includes a built-in `github-runner` template that
automates all runner setup:

```bash
spook create runner-01 \
    --pull ghcr.io/spooktacular/macos-xcode:15.4-16.2 \
    --template github-runner \
    --template-arg repo=myorg/myrepo \
    --template-arg token=ghp_xxxx \
    --template-arg labels=macos,arm64,xcode16
```

The template:

1. Downloads the latest GitHub Actions runner binary
2. Registers the runner with your repository (or organization)
3. Configures labels for workflow targeting
4. Installs the runner as a LaunchDaemon for automatic startup
5. Optionally configures ephemeral mode for single-use VMs

### Template Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `repo` | Yes (or `org`) | GitHub repository (e.g., `myorg/myrepo`) |
| `org` | Yes (or `repo`) | GitHub organization for org-level runners |
| `token` | Yes | GitHub PAT or registration token |
| `labels` | No | Comma-separated runner labels |
| `group` | No | Runner group name (org-level only) |
| `name` | No | Runner name (defaults to VM name) |

## Ephemeral Runners

Ephemeral runners are destroyed and recreated after every job.
This guarantees a clean, unmodified environment for each CI run,
eliminating "works on my runner" issues.

### How Ephemeral Mode Works

1. VM boots with a fresh macOS image
2. Runner registers with GitHub using `--ephemeral` flag
3. Runner picks up one job and executes it
4. Job completes, runner deregisters itself
5. Spooktacular destroys the VM
6. A new VM is created from the same base image
7. Cycle repeats

### CLI Setup

```bash
# Create an ephemeral runner that auto-replaces
spook create runner-01 \
    --pull ghcr.io/spooktacular/macos-xcode:15.4-16.2 \
    --template github-runner \
    --template-arg repo=myorg/myrepo \
    --template-arg token=ghp_xxxx \
    --ephemeral
```

### Kubernetes Setup

```yaml
apiVersion: spooktacular.io/v1alpha1
kind: MacOSVMPool
metadata:
  name: ephemeral-runners
spec:
  replicas: 4
  image: ghcr.io/spooktacular/macos-xcode:15.4-16.2
  template: github-runner
  templateArgs:
    repo: myorg/myrepo
    token: ghp_xxxxxxxxxxxx
    labels: macos,arm64,xcode16
  ephemeral: true
  provisioning:
    mode: agent
```

The operator automatically replaces each VM after its job completes.

## Runner Pool with Auto-Replacement

For persistent (non-ephemeral) runners that still get replaced on
failure:

```bash
#!/bin/bash
# pool-manager.sh — runs on the Mac host

POOL_SIZE=2
IMAGE="ghcr.io/spooktacular/macos-xcode:15.4-16.2"

while true; do
    running=$(spook list --json | jq '[.[] | select(.name | startswith("runner-"))] | length')

    for i in $(seq 1 $POOL_SIZE); do
        name="runner-$(printf '%02d' $i)"

        if ! spook list --json | jq -e ".[] | select(.name == \"$name\")" > /dev/null 2>&1; then
            echo "Replacing $name..."
            spook create "$name" \
                --pull "$IMAGE" \
                --cpu 4 --memory 8 --disk 64 \
                --template github-runner \
                --template-arg repo=myorg/myrepo \
                --template-arg token=ghp_xxxx

            spook start "$name" --headless
        fi
    done

    sleep 60
done
```

## Webhook-Driven Autoscaling

Scale your runner pool based on actual demand using GitHub webhook
events.

### Architecture

```
GitHub ──workflow_job event──▶ Webhook Receiver ──▶ Scale MacOSVMPool
```

When a `workflow_job` event with `action: queued` arrives, the
autoscaler increases the pool size. When `action: completed`, it
decreases after the idle timeout.

### Kubernetes Configuration

```yaml
apiVersion: spooktacular.io/v1alpha1
kind: MacOSVMPool
metadata:
  name: autoscale-runners
spec:
  replicas: 2
  image: ghcr.io/spooktacular/macos-xcode:15.4-16.2
  template: github-runner
  templateArgs:
    repo: myorg/myrepo
    token: ghp_xxxxxxxxxxxx
    labels: macos,arm64
  ephemeral: true
  scaling:
    minReplicas: 0
    maxReplicas: 8
    idleTimeout: 5m
    webhook:
      path: /webhook/github
      secret: github-webhook-secret
```

### GitHub Webhook Setup

1. Go to your repository or organization Settings > Webhooks
2. Add a webhook:
   - **Payload URL:** `https://your-operator.example.com/webhook/github`
   - **Content type:** `application/json`
   - **Secret:** The value in your `github-webhook-secret` K8s Secret
   - **Events:** Select "Workflow jobs"

### Webhook Secret

```bash
kubectl create secret generic github-webhook-secret \
    --from-literal=secret="$(openssl rand -hex 32)" \
    -n spooktacular-system
```

## GitHub App vs PAT for Runner Registration

### Personal Access Token (PAT)

Simpler to set up, but less secure for organizations:

```bash
# Fine-grained PAT with "Administration" repository permission (read/write)
# Or classic PAT with "repo" scope
TOKEN="ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

spook create runner \
    --template github-runner \
    --template-arg repo=myorg/myrepo \
    --template-arg token="$TOKEN"
```

> Note: Classic PATs with `repo` scope grant broad access. Prefer
> fine-grained PATs with only the "Administration" permission.

### GitHub App (Recommended for Organizations)

More secure — the app generates short-lived tokens:

```bash
# 1. Create a GitHub App with "Self-hosted runners" organization permission
# 2. Install the app on your organization
# 3. Generate an installation access token

APP_ID="123456"
PRIVATE_KEY_PATH="./my-app.pem"
INSTALLATION_ID="789012"

# Generate a JWT
JWT=$(python3 -c "
import jwt, time
payload = {'iat': int(time.time()), 'exp': int(time.time()) + 600, 'iss': '$APP_ID'}
print(jwt.encode(payload, open('$PRIVATE_KEY_PATH').read(), algorithm='RS256'))
")

# Exchange for an installation token
TOKEN=$(curl -s -X POST \
    -H "Authorization: Bearer $JWT" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/$INSTALLATION_ID/access_tokens" \
    | jq -r .token)

spook create runner \
    --template github-runner \
    --template-arg org=myorg \
    --template-arg token="$TOKEN"
```

## Xcode Version Management

### Multiple Base Images

Maintain base images for each Xcode version your projects need:

```bash
# Create base images for different Xcode versions
spook create base-xcode15 --from-ipsw latest --cpu 4 --memory 8 --disk 100
spook start base-xcode15
# Install Xcode 15.4, accept license, run first launch
spook stop base-xcode15

spook create base-xcode16 --from-ipsw latest --cpu 4 --memory 8 --disk 100
spook start base-xcode16
# Install Xcode 16.2, accept license, run first launch
spook stop base-xcode16

# Clone runners from the appropriate base
spook clone base-xcode15 runner-xcode15-01
spook clone base-xcode16 runner-xcode16-01
```

### Using OCI Images with Xcode

Pre-built OCI images include Xcode, saving setup time:

```bash
# Xcode 15.4 on macOS 15.4
spook create runner --pull ghcr.io/spooktacular/macos-xcode:15.4-15.4

# Xcode 16.2 on macOS 15.4
spook create runner --pull ghcr.io/spooktacular/macos-xcode:15.4-16.2
```

### Workflow Targeting

Use runner labels to target specific Xcode versions in your
workflows:

```yaml
# .github/workflows/build.yml
jobs:
  build-ios:
    runs-on: [self-hosted, macos, arm64, xcode16]
    steps:
      - uses: actions/checkout@v4
      - run: xcodebuild -version
      - run: xcodebuild -scheme MyApp -sdk iphoneos build

  build-legacy:
    runs-on: [self-hosted, macos, arm64, xcode15]
    steps:
      - uses: actions/checkout@v4
      - run: xcodebuild -scheme MyApp -sdk iphoneos build
```

## Scaling with Kubernetes

### MacOSVMPool for GitHub Actions

The most robust scaling approach uses the Kubernetes operator with
a `MacOSVMPool`:

```yaml
apiVersion: spooktacular.io/v1alpha1
kind: MacOSVMPool
metadata:
  name: xcode16-runners
  namespace: ci
spec:
  replicas: 6
  image: ghcr.io/spooktacular/macos-xcode:15.4-16.2
  resources:
    cpu: 4
    memory: 8Gi
    disk: 64Gi
  template: github-runner
  templateArgs:
    org: myorg
    token: ghp_xxxxxxxxxxxx
    labels: macos,arm64,xcode16
  ephemeral: true
  provisioning:
    mode: agent
  scaling:
    minReplicas: 2
    maxReplicas: 6
    idleTimeout: 10m
    webhook:
      path: /webhook/github
      secret: github-webhook-secret
```

See <doc:KubernetesGuide> for the full Kubernetes setup.

## EC2 Mac Fleet for GitHub Actions

A complete production setup using EC2 Mac hosts:

### Step 1: Provision EC2 Mac Hosts

```hcl
# terraform/main.tf
module "runner_fleet" {
  source = "spooktacular/ec2-mac/aws"

  host_count       = 5
  instance_type    = "mac2-m2pro.metal"
  subnet_ids       = module.vpc.private_subnets
  security_groups  = [aws_security_group.runners.id]
  key_name         = aws_key_pair.deploy.key_name
  vms_per_host     = 2
  vm_image         = "ghcr.io/spooktacular/macos-xcode:15.4-16.2"
  github_org       = "myorg"
  github_token_ssm = aws_ssm_parameter.github_token.name
}
```

### Step 2: Install the Kubernetes Operator

```bash
helm install spooktacular-operator spooktacular/operator \
    --namespace spooktacular-system \
    --create-namespace \
    -f values.yaml
```

### Step 3: Deploy the Runner Pool

```yaml
apiVersion: spooktacular.io/v1alpha1
kind: MacOSVMPool
metadata:
  name: production-runners
  namespace: ci
spec:
  replicas: 10
  image: ghcr.io/spooktacular/macos-xcode:15.4-16.2
  template: github-runner
  templateArgs:
    org: myorg
    token: ghp_xxxxxxxxxxxx
    labels: macos,arm64,xcode16,production
  ephemeral: true
  scaling:
    minReplicas: 4
    maxReplicas: 10
    idleTimeout: 15m
```

### Capacity Planning

| EC2 Mac hosts | Instance type | Runners | Monthly cost (on-demand) | Per runner |
|---------------|---------------|---------|-------------------------|------------|
| 3 | mac2.metal (M1) | 6 | ~$2,340 | ~$390 |
| 5 | mac2-m2pro.metal | 10 | ~$3,900 | ~$390 |
| 10 | mac2-m2pro.metal | 20 | ~$7,800 | ~$390 |

Compare to GitHub-hosted macOS runners at ~$2,400/runner/month (L size).

See <doc:EC2MacDeployment> for detailed EC2 Mac cost optimization.

## Cost Comparison

### Monthly Cost per macOS Runner

| Provider | Runner type | Cost/month | Clean env? | GPU access? |
|----------|-----------|-----------|------------|-------------|
| GitHub-hosted | macOS L (12 cores) | ~$2,400 | Yes | No |
| GitHub-hosted | macOS XL (M1) | ~$4,800 | Yes | Yes |
| EC2 Mac (bare metal) | 1 runner/host | ~$780 | Manual | Yes |
| **Spooktacular on EC2 Mac** | **2 runners/host** | **~$390** | **Yes (ephemeral)** | **Yes** |
| Mac mini colo | 2 runners/mini | ~$50-100 | Yes (ephemeral) | Yes |

### Annual Savings Example

A team running 10 macOS CI runners:

| Approach | Annual cost | vs GitHub-hosted |
|----------|-----------|-----------------|
| GitHub-hosted (L) | $288,000 | baseline |
| EC2 Mac bare metal | $93,600 | -67% |
| **Spooktacular on EC2 Mac** | **$46,800** | **-84%** |
| Spooktacular on colo Mac minis | $6,000-12,000 | -96% |

## Monitoring Runner Health

### From the CLI

```bash
# Check VM status
spook list
spook get runner-01

# Check if runners are connected to GitHub
curl -s -H "Authorization: token ghp_xxxx" \
    "https://api.github.com/repos/myorg/myrepo/actions/runners" | \
    jq '.runners[] | {name, status, busy}'
```

### From Kubernetes

```bash
# Pool health
kubectl get macosvmpool -n ci
kubectl describe macosvmpool production-runners -n ci

# Individual runner VMs
kubectl get macosvm -n ci

# Operator logs
kubectl logs -n spooktacular-system deployment/spooktacular-operator -f
```

### Health Check Script

```bash
#!/bin/bash
# check-runners.sh — verify runners are healthy

REPO="myorg/myrepo"
TOKEN="ghp_xxxx"

runners=$(curl -s -H "Authorization: token $TOKEN" \
    "https://api.github.com/repos/$REPO/actions/runners" | \
    jq -r '.runners[] | "\(.name) \(.status) \(.busy)"')

echo "Runner Status:"
echo "$runners" | while read name status busy; do
    if [ "$status" = "online" ]; then
        echo "  $name: online (busy=$busy)"
    else
        echo "  $name: OFFLINE — needs attention"
    fi
done

offline_count=$(echo "$runners" | grep -c "offline" || true)
if [ "$offline_count" -gt 0 ]; then
    echo ""
    echo "WARNING: $offline_count runner(s) offline"
    exit 1
fi
```

## Troubleshooting

### Runner Not Picking Up Jobs

**Symptom:** Jobs queue but no runner starts executing them.

**Cause:** Label mismatch between the workflow `runs-on` and the
runner's configured labels.

**Solution:**

```bash
# Check runner labels in GitHub
curl -s -H "Authorization: token ghp_xxxx" \
    "https://api.github.com/repos/myorg/myrepo/actions/runners" | \
    jq '.runners[] | {name, labels: [.labels[].name]}'

# Verify workflow runs-on matches
# .github/workflows/build.yml:
#   runs-on: [self-hosted, macos, arm64, xcode16]
# Runner must have ALL of these labels.
```

### Token Expiry

**Symptom:** Runner fails to register or deregisters unexpectedly.

**Cause:** The GitHub PAT or registration token has expired.

**Solution:**

```bash
# For PATs: generate a new token in GitHub Settings > Developer settings
# For GitHub Apps: tokens auto-refresh, but check the app installation

# Update the token in your VM pool
kubectl edit macosvmpool production-runners -n ci
# Update templateArgs.token

# Or rotate via Helm
helm upgrade spooktacular-operator spooktacular/operator \
    --set pools.runners.templateArgs.token=ghp_NEW_TOKEN
```

### Disk Full

**Symptom:** Builds fail with "No space left on device" inside
the runner VM.

**Cause:** The VM's disk image has reached its configured maximum,
or build artifacts have accumulated.

**Solution:**

```bash
# Check disk usage inside the VM
spook exec runner-01 -- df -h /

# For ephemeral runners, this is self-correcting — the VM is
# destroyed after each job. If using persistent runners:
spook exec runner-01 -- rm -rf /Users/admin/actions-runner/_work/_temp/*
spook exec runner-01 -- xcrun simctl delete unavailable

# Or increase disk size for new VMs
spook create runner --cpu 4 --memory 8 --disk 128
```

### VM Stuck in Starting State

**Symptom:** `spook list` shows the VM in `starting` state
indefinitely.

**Cause:** Typically a resource contention issue or a corrupt VM
bundle.

**Solution:**

```bash
# Force stop and restart
spook stop runner-01
spook start runner-01 --headless

# If that fails, delete and recreate from the base image
spook delete runner-01 --force
spook clone base-xcode16 runner-01
spook start runner-01 --headless
```

## Topics

### Related Guides

- <doc:GettingStarted>
- <doc:EC2MacDeployment>
- <doc:KubernetesGuide>
- <doc:Provisioning>
- <doc:CLIReference>

### Key Types

- ``VMSpec``
- ``VMBundle``
- ``CloneManager``
- ``ProvisioningMode``
- ``VMState``
