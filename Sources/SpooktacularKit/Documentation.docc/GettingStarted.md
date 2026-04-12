# Getting Started with Spooktacular

Create your first macOS virtual machine in minutes.

## Overview

Spooktacular runs macOS virtual machines on Apple Silicon using
Apple's Virtualization framework. You can use the GUI app, the
`spook` CLI, or the Kubernetes operator — all backed by the same
``SpooktacularKit`` library.

### Prerequisites

- Apple Silicon Mac (M1 or later)
- macOS 14.0 (Sonoma) or later
- At least 20 GB free disk space per VM

### Creating a VM with the CLI

The fastest way to create a VM:

```bash
# Create from the latest compatible IPSW
spook create my-vm --from-ipsw latest

# Or with custom hardware
spook create runner --cpu 8 --memory 16 --disk 100
```

### Creating a VM with the GUI

1. Open Spooktacular
2. Click the **+** button or press **Cmd+N**
3. Enter a name and adjust hardware settings
4. Click **Create**

### Managing VMs

```bash
# List all VMs
spook list

# Start a VM (opens display window)
spook start my-vm

# Start headless (for CI runners)
spook start my-vm --headless

# Clone instantly (APFS copy-on-write)
spook clone my-vm runner-01

# Show VM configuration
spook get my-vm

# Delete a VM
spook delete my-vm --force
```

### User-Data Scripts

Run a shell script automatically after the VM boots:

```bash
spook create runner --from-ipsw latest \
    --user-data ~/setup.sh \
    --provision disk-inject
```

See ``ProvisioningMode`` for all four provisioning strategies.

### Kubernetes Integration

Manage VMs as Kubernetes resources:

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

### EC2 Mac Setup

Double your CI capacity on AWS:

```bash
curl -sSL https://spooktacular.dev/ec2-setup.sh | bash -s -- \
    --github-repo myorg/myrepo \
    --github-token ghp_xxx \
    --xcode 16.2
```

## Topics

### Core Types

- ``VMBundle``
- ``VMSpec``
- ``VirtualMachine``

### Configuration

- ``VMConfiguration``
- ``NetworkMode``
- ``ProvisioningMode``
