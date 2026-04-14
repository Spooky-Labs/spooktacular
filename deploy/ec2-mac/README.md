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

## Quick Start with Terraform

The fastest path from zero to running VMs:

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
3. Run `bootstrap.sh` as user-data to install and configure Spooktacular
4. Output the instance IP and SSH command

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

## Manual Setup Alternative

If you prefer to set up without Terraform:

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

### 3. Or run bootstrap via SSM after launch

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

## Cost Optimization

- **24-hour minimum.** Dedicated Hosts have a 24-hour minimum allocation.
  Releasing a host before 24 hours still incurs the full charge. Batch your
  work to maximize utilization within each allocation window.

- **Host Resource Groups.** Use AWS License Manager Host Resource Groups for
  automatic Dedicated Host management. AWS will allocate and release hosts
  based on demand, which helps avoid paying for idle hosts:
  ```bash
  aws license-manager create-license-configuration \
    --name "macOS-EULA" \
    --license-counting-type "Core" \
    --license-count 999
  ```

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

# Run across all Mac instances
aws ssm send-command \
  --document-name "SpooktacularInstall" \
  --targets "Key=tag:Role,Values=spooktacular-host"
```

## Related Documentation

- [Main README](../../README.md) -- Project overview, CLI reference, and Quick Start
- [Kubernetes Integration](../kubernetes/README.md) -- Managing VMs as K8s custom resources
- [API Documentation](https://spooktacular.app/api/documentation/spooktacularkit/) -- Full HTTP API reference
