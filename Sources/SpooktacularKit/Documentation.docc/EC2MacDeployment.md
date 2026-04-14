# Deploying on EC2 Mac

Run Spooktacular on AWS EC2 Mac dedicated hosts to double your macOS CI capacity.

## Overview

AWS EC2 Mac instances provide bare-metal Apple Silicon hardware in the
cloud. Each EC2 Mac host can run a single macOS instance natively, but
with Spooktacular you can run **two** macOS virtual machines per host —
doubling your CI runner capacity without adding hardware.

This guide covers the complete setup: from allocating a dedicated host
to running a production GitHub Actions fleet on EC2 Mac.

### Prerequisites

Before you begin, ensure you have:

- **AWS account** with EC2 Mac instance access (may require a service
  quota increase for `mac2.metal` or `mac2-m2.metal`)
- **EC2 Mac dedicated host** — Mac instances run exclusively on
  dedicated hosts (not shared tenancy)
- **VPC with a private subnet** — recommended for security
- **Security group** allowing SSH (port 22) from your bastion or VPN
- **SSH key pair** for EC2 access
- Apple Silicon Mac host types: `mac2.metal` (M1), `mac2-m2.metal`
  (M2), or `mac2-m2pro.metal` (M2 Pro)

> Important: EC2 Mac dedicated hosts have a **24-hour minimum allocation
> period**. You are billed for the full 24 hours even if you release the
> host earlier. Plan your usage accordingly.

## Quick Setup

SSH into your EC2 Mac instance, install Spooktacular, create VMs,
and start runners with SSH provisioning:

```bash
# Install Spooktacular
brew install --cask spooktacular

# Install the LaunchDaemon for headless operation
spook service install

# Create and configure a base VM
spook create base --from-ipsw latest --cpu 4 --memory 8 --disk 64
spook start base
# ... install Xcode, enable SSH, configure settings
spook stop base

# Clone runners and start with provisioning
spook clone base runner-01
spook clone base runner-02
spook start runner-01 --headless \
    --user-data ~/github-runner-setup.sh --provision ssh --ssh-user admin
spook start runner-02 --headless \
    --user-data ~/github-runner-setup.sh --provision ssh --ssh-user admin
```

## Manual Step-by-Step Setup

If you prefer to configure each step yourself, follow this procedure.

### Step 1: Install Spooktacular

SSH into your EC2 Mac instance and install via Homebrew:

```bash
ssh -i ~/.ssh/my-key.pem ec2-user@<ec2-public-ip>

# Install Homebrew if not already present
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install Spooktacular
brew install --cask spooktacular
```

Verify the installation:

```bash
spook --version
# spook 0.1.0
```

### Step 2: Install the LaunchDaemon

Register Spooktacular as a system service for headless operation:

```bash
spook service install
```

> Note: `spook service install` creates a LaunchDaemon plist at
> `/Library/LaunchDaemons/dev.spooktacular.daemon.plist`.

> Note: An HTTP control API for remote management is planned for a
> future release. For now, manage VMs via SSH + CLI.

The LaunchDaemon starts on system boot, restarts automatically
on crash, and ensures VMs survive SSH session termination.

### LaunchDaemon vs LaunchAgent

| Service Type | Runs as | Starts at | Best for |
|-------------|---------|-----------|----------|
| LaunchDaemon | root | System boot | Servers, CI hosts, EC2 Mac |
| LaunchAgent | User | User login | Developer workstations |

For EC2 Mac deployments, always use the LaunchDaemon (`spook service
install`). LaunchAgents require an active GUI session and are not
suitable for headless server operation.

```bash
# LaunchDaemon (recommended for EC2 Mac)
spook service install

# LaunchAgent (for developer machines)
spook service install --user
```

## Security Best Practices

1. **VPC private subnet** — Place EC2 Mac hosts in a private subnet
   with no public IP. Access via VPN, bastion, or VPC peering.
2. **Security group** — Allow SSH (port 22) only from your bastion
   or VPN CIDR.
3. **IAM** — Use EC2 instance roles for AWS API access. Do not store
   long-lived AWS credentials on the host.

> Note: An HTTP control API for remote VM management is planned for a
> future release. For now, manage VMs by SSH-ing into the host and
> using the `spook` CLI directly.

## Creating VMs on the EC2 Mac

### From an IPSW (Fresh Install)

```bash
# Download the latest compatible macOS and install
spook create runner-01 --from-ipsw latest \
    --cpu 4 --memory 8 --disk 64

# Create a second VM (2 per host maximum)
spook create runner-02 --from-ipsw latest \
    --cpu 4 --memory 8 --disk 64
```

> Note: IPSW installation takes 10-20 minutes per VM. For faster
> deployment, create one base VM, configure it, then use
> `spook clone` for instant copies.

### From a Clone (Recommended for Fast Deployment)

Create one base VM, configure it with Xcode, then clone instantly:

```bash
# Clone from the base for instant deployment
spook clone base runner-01
spook clone base runner-02
```

> Note: OCI image push/pull is planned for a future release.

### Clone from a Base VM

Create one base VM, configure it, then clone instantly:

```bash
# Create and configure a base VM
spook create base --from-ipsw latest --cpu 4 --memory 8 --disk 64
spook start base
# ... manually install Xcode, configure settings, etc.
spook stop base

# Clone instantly (APFS copy-on-write, milliseconds)
spook clone base runner-01
spook clone base runner-02
```

See ``CloneManager`` for details on how APFS copy-on-write cloning
works.

### Provisioning with User-Data

Automate VM setup with a user-data script via SSH provisioning:

```bash
spook start runner-01 --headless \
    --user-data /opt/spooktacular/setup-runner.sh \
    --provision ssh --ssh-user admin
```

See <doc:Provisioning> for available provisioning modes.

## Monitoring

### Checking VM Status

```bash
# List all VMs with status
spook list

# JSON output for automation
spook list --json

# Detailed configuration for a specific VM
spook get runner-01

# Extract a single field for scripting
spook get runner-01 --field cpu
```

### Logs

```bash
# Spooktacular service logs (LaunchDaemon)
log show --predicate 'subsystem == "dev.spooktacular"' --last 1h

# System-level VM logs
log show --predicate 'subsystem == "com.apple.Virtualization"' --last 1h
```

### Disk Usage

Monitor disk space carefully. Each VM's disk image is APFS sparse
but can grow to its configured maximum:

```bash
# Check host disk usage
df -h /

# Check actual disk image sizes (sparse files)
du -sh ~/.spooktacular/vms/*/disk.img

# Check configured vs actual size
spook get runner-01 --field disk
```

## Cost Optimization

### The Math

EC2 Mac dedicated hosts cost approximately **$1.083/hour** (M1,
`us-east-1`, on-demand pricing as of 2025). With a 24-hour minimum
allocation:

| Scenario | Hosts | Runners | Monthly cost | Cost per runner |
|----------|-------|---------|-------------|-----------------|
| Without Spooktacular | 10 | 10 | ~$7,800 | ~$780 |
| With Spooktacular | 10 | **20** | ~$7,800 | ~$390 |
| With Spooktacular | 5 | 10 | ~$3,900 | ~$390 |

Spooktacular halves the per-runner cost by running 2 VMs per host.

### Hardware Allocation

Each EC2 Mac `mac2.metal` (M1) has 8 CPU cores and 16 GB RAM. A
recommended split for two VMs:

```bash
# Runner 1: 4 cores, 8 GB RAM
spook create runner-01 --cpu 4 --memory 8 --disk 64

# Runner 2: 4 cores, 8 GB RAM
spook create runner-02 --cpu 4 --memory 8 --disk 64
```

For M2 Pro hosts (`mac2-m2pro.metal`) with 12 cores and 32 GB RAM:

```bash
# Runner 1: 6 cores, 16 GB RAM
spook create runner-01 --cpu 6 --memory 16 --disk 100

# Runner 2: 6 cores, 16 GB RAM
spook create runner-02 --cpu 6 --memory 16 --disk 100
```

### Savings Plans and Reserved Instances

AWS offers Savings Plans for EC2 Mac dedicated hosts with up to 44%
discount for a 1-year commitment. Combine Spooktacular's 2x
capacity with a Savings Plan for maximum cost efficiency.

## Auto Scaling Group Integration

Use an EC2 Auto Scaling Group to manage a fleet of Mac hosts. Each
host runs the setup script via user-data on launch:

### Launch Template

```bash
aws ec2 create-launch-template \
    --launch-template-name spooktacular-mac \
    --launch-template-data '{
        "ImageId": "ami-0xxxxxxxxxxxx",
        "InstanceType": "mac2.metal",
        "KeyName": "my-key",
        "SecurityGroupIds": ["sg-0xxxxxxxxxxxx"],
        "UserData": "'$(base64 -w0 ec2-setup.sh)'"
    }'
```

### User-Data Script

```bash
#!/bin/bash
set -euo pipefail

# Install Spooktacular
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/opt/homebrew/bin/brew shellenv)"
brew install --cask spooktacular

# Install the LaunchDaemon
sudo spook service install

# Create two runners from IPSW
spook create runner-01 --from-ipsw latest --cpu 4 --memory 8 --disk 64
spook create runner-02 --from-ipsw latest --cpu 4 --memory 8 --disk 64

# Start with SSH provisioning
spook start runner-01 --headless \
    --user-data /opt/spooktacular/github-runner.sh \
    --provision ssh --ssh-user admin
spook start runner-02 --headless \
    --user-data /opt/spooktacular/github-runner.sh \
    --provision ssh --ssh-user admin
```

## Terraform Module (Planned)

> Note: A Terraform module for declarative EC2 Mac fleet management
> is planned for a future release. For now, use EC2 Launch Templates
> with user-data scripts to automate host setup.

## Troubleshooting

### IPSW Version Mismatch

**Symptom:** `spook create` fails with "Your macOS (X.Y) cannot
install macOS Z.W."

**Cause:** The EC2 Mac host's macOS is older than the IPSW you are
trying to install. The guest version must be less than or equal to
the host version.

**Solution:** Update the host macOS to a version that supports the
guest you want to install:

```bash
# Check host version
sw_vers --productVersion

# Use --from-ipsw with a compatible version
spook create runner --from-ipsw latest
```

See ``Compatibility`` for details on how version checking works.

### Disk Space Exhausted

**Symptom:** VM creation or operation fails with I/O errors.

**Cause:** APFS sparse disk images grow as the guest writes data.
Two VMs with 100 GB configured disk can consume up to 200 GB.

**Solution:** Monitor disk usage and size VMs appropriately:

```bash
# Check actual disk usage
du -sh ~/.spooktacular/vms/*/disk.img

# EC2 Mac root volume is typically 200 GB — resize if needed
aws ec2 modify-volume --volume-id vol-0xxxx --size 500
# Then resize the filesystem inside the instance
sudo diskutil apfs resizeContainer disk1 0
```

### 24-Hour Minimum Allocation

**Symptom:** You are billed for 24 hours even though you released
the dedicated host after 2 hours.

**Cause:** EC2 Mac dedicated hosts have a mandatory 24-hour minimum
allocation period. This is an AWS policy, not a Spooktacular
limitation.

**Solution:** Plan your usage in 24-hour blocks. Use Auto Scaling
Groups with scheduled scaling to align host allocation with your
CI load patterns:

```bash
# Scale up at 8 AM UTC (start of business)
aws autoscaling put-scheduled-action \
    --auto-scaling-group-name spooktacular-fleet \
    --scheduled-action-name scale-up \
    --recurrence "0 8 * * MON-FRI" \
    --desired-capacity 10

# Scale down at 8 PM UTC (end of business)
# Hosts won't actually release until 24hr mark
aws autoscaling put-scheduled-action \
    --auto-scaling-group-name spooktacular-fleet \
    --scheduled-action-name scale-down \
    --recurrence "0 20 * * MON-FRI" \
    --desired-capacity 2
```

### VM Won't Start

**Symptom:** `spook start` hangs or the VM enters the
``VirtualMachineState/error`` state.

**Cause:** Common causes include insufficient resources (too many
cores allocated across VMs), corrupt disk image, or the Apple
kernel 2-VM limit.

**Solution:**

```bash
# Check how many VMs are running (max 2)
spook list

# Verify resource allocation
spook get runner-01

# Check system logs
log show --predicate 'subsystem == "com.apple.Virtualization"' --last 5m
```

> Important: Apple's Virtualization framework enforces a hard limit
> of **2 concurrent VMs** per host. Attempting to start a third VM
> will fail. See ``VirtualMachineSpecification/minimumCPUCount`` for minimum hardware
> requirements.

## Topics

### Related Guides

- <doc:GettingStarted>
- <doc:KubernetesGuide>
- <doc:GitHubActionsGuide>
- <doc:Provisioning>

### Key Types

- ``VirtualMachineSpecification``
- ``VirtualMachineBundle``
- ``CloneManager``
- ``Compatibility``
- ``RestoreImageManager``
- ``VirtualMachineState``
