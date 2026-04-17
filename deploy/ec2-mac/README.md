# Spooktacular on EC2 Mac

Turn one EC2 Mac instance into two macOS worker slots. This package provides
everything you need to deploy Spooktacular on AWS EC2 Mac Dedicated Hosts --
Terraform, bootstrap scripts, and SSM documents for fleet-wide management.

## What This Does

A single `mac2.metal` EC2 instance becomes **two fully independent macOS VMs**,
each capable of running CI/CD jobs, remote desktops, or any other macOS
workload. Spooktacular handles provisioning, lifecycle, and networking.

**Apple EULA compliance:** Section 2B(iii) of the Apple macOS EULA permits
running up to 2 additional instances of macOS in virtual machines on each Apple
computer you own or control. AWS Dedicated Hosts provide the required physical
isolation -- each Dedicated Host is a single physical Mac allocated exclusively
to your account.

## Architecture

```
                          AWS Cloud
 ┌─────────────────────────────────────────────────────────────────┐
 │                       VPC / Subnet                              │
 │                                                                 │
 │  ┌───────────────────────────────────────────────────────────┐  │
 │  │          EC2 Mac Dedicated Host (mac2.metal)              │  │
 │  │                                                           │  │
 │  │  ┌─────────────────────────────────────────────────────┐  │  │
 │  │  │              EC2 Mac Instance                       │  │  │
 │  │  │                                                     │  │  │
 │  │  │   spook serve :8484 (TLS + bearer token auth)       │  │  │
 │  │  │                                                     │  │  │
 │  │  │   ┌──────────────┐     ┌──────────────┐             │  │  │
 │  │  │   │  macOS VM 1  │     │  macOS VM 2  │             │  │  │
 │  │  │   │              │     │              │             │  │  │
 │  │  │   │  CI runner   │     │  CI runner   │             │  │  │
 │  │  │   │  or desktop  │     │  or desktop  │             │  │  │
 │  │  │   └──────────────┘     └──────────────┘             │  │  │
 │  │  │                                                     │  │  │
 │  │  └─────────────────────────────────────────────────────┘  │  │
 │  └───────────────────────────────────────────────────────────┘  │
 │                              │                                   │
 │                              │ :8484 (HTTPS)                     │
 │                              ▼                                   │
 │                  ┌────────────────────┐                          │
 │                  │  K8s Controller    │                          │
 │                  │  (optional)        │                          │
 │                  │                    │                          │
 │                  │  Manages VMs via   │                          │
 │                  │  MacOSVM CRD       │                          │
 │                  └────────────────────┘                          │
 └─────────────────────────────────────────────────────────────────┘
```

## Prerequisites

1. **AWS account** with EC2 Mac Dedicated Host access. You must request a
   service quota increase for `mac2.metal` Dedicated Hosts in your target
   region if you have not used them before.

2. **Dedicated Host allocation.** EC2 Mac instances run exclusively on
   Dedicated Hosts. AWS enforces a **24-hour minimum allocation** -- you are
   billed for the full 24 hours even if the instance runs for less time. Plan
   accordingly.

3. **macOS 14+ AMI.** Use an Apple-provided macOS Sonoma (14) or Sequoia (15)
   AMI. Find the latest AMI ID with:
   ```bash
   aws ec2 describe-images \
     --owners amazon \
     --filters "Name=name,Values=amzn-ec2-macos-14*" \
     --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
     --output text
   ```

4. **VPC and subnet** with internet access (for downloading Spooktacular and
   macOS restore images). The subnet must be in the same Availability Zone as
   the Dedicated Host.

5. **SSH key pair** registered in the target region.

## Quick Start

### Option 1: Systems Manager (Recommended for Enterprise)

Install Spooktacular on an EC2 Mac fleet using AWS Systems Manager:

```bash
# Install on a single host
aws ssm send-command \
  --instance-ids i-0abc123def456 \
  --document-name "SpooktacularInstall" \
  --parameters 'Action=install'

# Install across a fleet
aws ssm send-command \
  --targets "Key=tag:spooktacular,Values=managed" \
  --document-name "SpooktacularInstall" \
  --parameters 'Action=install'
```

### Option 2: Terraform

Use the included Terraform module for automated Dedicated Host + instance provisioning.

```bash
cd deploy/ec2-mac/terraform

# Review and customize variables
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars

# Deploy
terraform init
terraform plan
terraform apply
```

Terraform will:
1. Allocate a Dedicated Host (`mac2.metal`)
2. Launch an EC2 Mac instance with the macOS AMI
3. Register the `SpooktacularInstall` SSM document from `ssm/install-spooktacular.yaml`
4. Run `bootstrap.sh` as user-data to install and configure Spooktacular
5. Create CloudWatch alarms for host utilization, API errors, audit export failures, TLS expiry, and ASG capacity gaps
6. (Optional, `enable_license_manager = true`) Create a License Manager license configuration and Host Resource Group
7. (Optional, `enable_asg = true`) Provision a launch template, ASG, and drain-on-terminate lifecycle hook
8. Output the instance IP and SSH command

After apply completes, wait 5-10 minutes for user-data to finish, then
validate:

```bash
# SSH into the instance
ssh -i ~/.ssh/your-key.pem ec2-user@<instance-ip>

# Check Spooktacular status
spook doctor

# List available VM slots
spook list
```

### Option 3: Manual Install (Development Only)

For local development or testing, download the signed binary from GitHub Releases:

```bash
# Download the latest signed release
curl -fsSL https://github.com/Spooky-Labs/spooktacular/releases/latest/download/spook -o /usr/local/bin/spook
chmod +x /usr/local/bin/spook
spook doctor
```

> **Note:** For production deployments, use SSM or the notarized .app/.pkg installer.
> Do not pipe untrusted scripts to bash in production environments.

## Manual Host Setup

If you need to provision the underlying infrastructure manually (without
Terraform), allocate a Dedicated Host and launch an instance before using
one of the install options above:

### 1. Allocate a Dedicated Host

```bash
aws ec2 allocate-hosts \
  --instance-type mac2.metal \
  --availability-zone us-east-1a \
  --quantity 1 \
  --tag-specifications 'ResourceType=dedicated-host,Tags=[{Key=Name,Value=spooktacular-host}]'
```

### 2. Launch an EC2 Mac instance

```bash
aws ec2 run-instances \
  --instance-type mac2.metal \
  --image-id ami-0123456789abcdef0 \
  --key-name your-key-pair \
  --placement "HostId=h-0123456789abcdef0" \
  --security-group-ids sg-0123456789abcdef0 \
  --user-data file://deploy/ec2-mac/bootstrap.sh
```

### 3. Install Spooktacular via SSM

```bash
aws ssm send-command \
  --document-name "SpooktacularInstall" \
  --targets "Key=instanceids,Values=i-0123456789abcdef0"
```

## Validation

After bootstrap completes, verify the installation:

```bash
# Run the built-in health check
spook doctor

# Expected output:
#   Virtualization: supported (Apple Silicon)
#   macOS version:  14.x or later
#   VM capacity:    2 slots available
#   API server:     running on :8484 (TLS enabled)
#   Base VM:        present (macOS 15)
#   Status:         ready

# Verify the API is reachable over TLS
curl -k https://localhost:8484/health

# List VMs (should show the base VM)
spook list
```

## Enterprise Features

### macOS Version Preflight

The bootstrap script validates the host environment before any provisioning:

1. **macOS 14+ (Sonoma)** -- required for Virtualization.framework features
   used by Spooktacular. The script calls `sw_vers -productVersion` and fails
   immediately with a clear message if the version is below 14.

2. **Apple Silicon (arm64)** -- Intel Macs are not supported.

3. **Host family detection** -- On EC2, the script queries IMDS for the
   instance type and logs which macOS versions are supported on that host
   family (e.g., mac2.metal supports macOS 12+, mac2-m2.metal supports 13+).

### Instance Identity-Based Tokens

API tokens are seeded with the EC2 instance identity instead of being purely
random. The bootstrap script queries IMDSv2 for the instance ID and uses it
as part of the token derivation:

```
IMDS session token (PUT /latest/api/token)
  -> instance-id (GET /latest/meta-data/instance-id)
  -> SHA-256(instance-id + timestamp + random) = API token
```

This ties each token to a specific EC2 instance, making token provenance
auditable. Tokens are still stored in the macOS Keychain (encrypted at rest).

### Host Resource Groups

Host Resource Groups (via AWS License Manager) enable automatic Dedicated
Host allocation and release. Instead of manually managing hosts, AWS
allocates them when instances need to launch and releases them when idle.

To use Host Resource Groups with Terraform:

```hcl
# In terraform.tfvars
host_resource_group_arn = "arn:aws:resource-groups:us-east-1:123456789012:group/my-mac-hrg"
```

Setup steps:

1. Create a License Configuration in AWS License Manager:
   ```bash
   aws license-manager create-license-configuration \
     --name "macOS-EULA" \
     --license-counting-type "Core" \
     --license-count 999
   ```

2. Create a Host Resource Group referencing the license configuration.

3. Pass the HRG ARN to the Terraform module via `host_resource_group_arn`.

The `hrg.tf` file in the Terraform module handles tagging the Dedicated Host
for group association. When the variable is `null` (default), no HRG
resources are created.

### Host Drain / Undrain

Drain mode allows graceful host decommissioning without interrupting running
VMs. When a host is drained:

- A marker file is written to `/etc/spooktacular/drain`
- `spook serve` checks for this file and stops accepting new VMs
- Existing VMs are allowed to finish their work
- When all VMs stop, the host reports "drained" to the controller

#### Via bootstrap.sh

```bash
# Drain a host (stop accepting new VMs)
ssh ec2-user@<ip> 'sudo bash /path/to/bootstrap.sh --drain'

# Undrain a host (resume accepting VMs)
ssh ec2-user@<ip> 'sudo bash /path/to/bootstrap.sh --undrain'
```

#### Via SSM (fleet-wide)

```bash
# Drain a specific host
aws ssm send-command \
  --document-name "SpooktacularInstall" \
  --targets "Key=instanceids,Values=i-0123456789abcdef0" \
  --parameters 'Action=drain'

# Undrain a specific host
aws ssm send-command \
  --document-name "SpooktacularInstall" \
  --targets "Key=instanceids,Values=i-0123456789abcdef0" \
  --parameters 'Action=undrain'

# Drain all hosts with a specific tag
aws ssm send-command \
  --document-name "SpooktacularInstall" \
  --targets "Key=tag:Role,Values=spooktacular-host" \
  --parameters 'Action=drain'
```

The SSM document's `Action` parameter accepts `install` (default), `drain`,
or `undrain`. When set to `drain` or `undrain`, only the relevant step runs
-- the full install pipeline is skipped.

## Cost Optimization

- **24-hour minimum.** Dedicated Hosts have a 24-hour minimum allocation.
  Releasing a host before 24 hours still incurs the full charge. Batch your
  work to maximize utilization within each allocation window.

- **Host Resource Groups.** Use AWS License Manager Host Resource Groups for
  automatic Dedicated Host management (see [Enterprise Features](#enterprise-features)
  above). AWS will allocate and release hosts based on demand, which helps
  avoid paying for idle hosts.

- **Savings Plans.** For steady-state workloads, Dedicated Host Savings Plans
  can reduce costs by up to 44% compared to On-Demand pricing.

- **Spot is not available.** EC2 Mac instances do not support Spot pricing
  because they require Dedicated Hosts.

## Fleet Management with SSM

For managing multiple EC2 Mac instances, use the included SSM document:

```bash
# Register the SSM document
aws ssm create-document \
  --name "SpooktacularInstall" \
  --document-type "Command" \
  --content file://deploy/ec2-mac/ssm/install-spooktacular.yaml \
  --document-format YAML

# Install across all Mac instances
aws ssm send-command \
  --document-name "SpooktacularInstall" \
  --targets "Key=tag:Role,Values=spooktacular-host"

# Drain a host (graceful decommission)
aws ssm send-command \
  --document-name "SpooktacularInstall" \
  --targets "Key=instanceids,Values=i-0123456789abcdef0" \
  --parameters 'Action=drain'

# Undrain a host (resume accepting VMs)
aws ssm send-command \
  --document-name "SpooktacularInstall" \
  --targets "Key=instanceids,Values=i-0123456789abcdef0" \
  --parameters 'Action=undrain'
```

The `Action` parameter accepts `install` (default), `drain`, or `undrain`.
See [Host Drain / Undrain](#host-drain--undrain) for details.

## Related Documentation

- [Main README](../../README.md) -- Project overview, CLI reference, and Quick Start
- [Kubernetes Integration](../kubernetes/README.md) -- Managing VMs as K8s custom resources
- [API Documentation](https://spooktacular.app/api/documentation/spooktacularkit/) -- Full HTTP API reference
