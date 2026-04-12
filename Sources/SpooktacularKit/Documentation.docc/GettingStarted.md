# Getting Started with Spooktacular

Create your first macOS virtual machine in minutes.

## Overview

Spooktacular runs macOS virtual machines on Apple Silicon using
Apple's Virtualization framework. You interact with it through the
GUI app, the `spook` CLI, or the Kubernetes operator --- all backed
by the same ``SpooktacularKit`` library.

> Important: You need an Apple Silicon Mac (M1 or later) running
> macOS 14.0 (Sonoma) or later. Each VM requires at least 20 GB of
> free disk space and 4 CPU cores (see
> ``VirtualMachineSpecification/minimumCPUCount``).

### Creating a VM with the CLI

Install Spooktacular and create a VM from the latest compatible IPSW:

```bash
# Install via Homebrew
brew install --cask spooktacular

# Create from the latest compatible IPSW
spook create my-vm --from-ipsw latest

# Or specify custom hardware resources
spook create runner --cpu 8 --memory 16 --disk 100
```

> Note: IPSW installation takes 10--20 minutes per VM. For faster
> deployment, create a base VM once, then use `spook clone` for
> instant copies.

### Creating a VM with the GUI

1. Open Spooktacular.
2. Click the **+** button or press **Cmd+N**.
3. Enter a name and adjust hardware settings.
4. Click **Create**.

The app downloads the latest compatible macOS IPSW and installs it
into a new VM bundle.

### Managing VMs

Use the `spook` CLI for day-to-day VM management:

```bash
# List all VMs
spook list

# Start a VM (opens display window)
spook start my-vm

# Start headless (for CI runners and servers)
spook start my-vm --headless

# Clone instantly using APFS copy-on-write
spook clone my-vm runner-01

# Show VM configuration
spook get my-vm

# Delete a VM permanently
spook delete my-vm --force
```

> Important: Apple Silicon supports a maximum of 2 concurrent VMs
> per host. Attempting to start a third VM fails. See
> ``CapacityCheck`` for details.

### Provisioning with User-Data Scripts

Automate VM setup by running a shell script on first boot:

```bash
spook create runner --from-ipsw latest \
    --user-data ~/setup.sh \
    --provision disk-inject
```

The `disk-inject` mode writes a LaunchDaemon to the guest disk
before the VM boots --- no SSH, no agent, and no prior configuration
required. See ``ProvisioningMode`` for all four provisioning
strategies and <doc:Provisioning> for detailed guidance.

### Kubernetes Integration

Manage VMs as Kubernetes resources using the Spooktacular operator:

```yaml
apiVersion: spooktacular.io/v1alpha1
kind: MacOSVM
metadata:
  name: ci-runner
spec:
  image: ghcr.io/spooktacular/macos-xcode:15.4-16.2
  resources:
    cpu: 4
    memory: 8Gi
    disk: 64Gi
  provisioning:
    mode: disk-inject
    userData: |
      #!/bin/bash
      echo "Hello from Kubernetes!"
```

See <doc:KubernetesGuide> for the complete Kubernetes setup.

### EC2 Mac Setup

Deploy Spooktacular on AWS EC2 Mac instances to double your CI
capacity:

```bash
curl -sSL https://spooktacular.dev/ec2-setup.sh | bash -s -- \
    --github-repo myorg/myrepo \
    --github-token ghp_xxx \
    --xcode 16.2
```

See <doc:EC2MacDeployment> for detailed EC2 Mac configuration.

## Topics

### Core Types

- ``VirtualMachineBundle``
- ``VirtualMachineSpecification``
- ``VirtualMachine``

### Configuration

- ``VirtualMachineConfiguration``
- ``NetworkMode``
- ``ProvisioningMode``

### Guides

- <doc:CLIReference>
- <doc:Provisioning>
- <doc:GitHubActionsGuide>
- <doc:EC2MacDeployment>
- <doc:KubernetesGuide>
