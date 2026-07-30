# Getting Started with Spooktacular

Create your first macOS virtual machine in minutes.

## Overview

Spooktacular runs macOS virtual machines on Apple Silicon using
Apple's Virtualization framework. You interact with it through the
GUI app or the `spook` CLI --- both backed by the same
``SpooktacularKit`` library.

> Important: You need an Apple Silicon Mac (M1 or later) running
> macOS 26.0 or later. Each VM requires at least 20 GB of
> free disk space and 4 CPU cores (see
> ``VirtualMachineSpecification/minimumCPUCount``).

### Creating a VM with the CLI

Install Spooktacular and create a VM from the latest compatible IPSW:

```bash
# Build from source — signed releases aren't published yet
git clone https://github.com/Spooky-Labs/spooktacular.git
cd spooktacular
./build-app.sh release

# Create from the latest compatible IPSW
spook create my-vm --from-ipsw latest

# Or specify custom hardware resources
spook create runner --cpu 8 --memory 16 --disk 100
```

> Note: the *first* macOS create installs macOS into a shared base image,
> which takes 10--20 minutes and needs root once. Every create after that
> is an overlay layer on that base and takes seconds. `spook clone` is
> faster still — a measured 30 ms for a 5 GB VM, using no extra disk,
> because APFS shares the blocks. See <doc:InstantCreate>.

### Creating a VM with the GUI

1. Open Spooktacular.
2. Click the **+** button or press **Cmd+N**.
3. Enter a name and adjust hardware settings.
4. Click **Create**.

The app downloads the latest compatible macOS IPSW and, the first time,
installs it into the shared base image; later creates reuse that base.

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

Automate VM setup by running a shell script after boot via SSH:

```bash
spook start runner --headless \
    --user-data ~/setup.sh \
    --provision ssh \
    --ssh-user admin
```

The `ssh` mode waits for the VM to boot, discovers its IP, connects
via SSH, and executes your script with real-time output streaming.
`--provision disk-inject` (the default) is zero-touch and needs no
SSH — it injects the script into the VM's disk image before first
boot via a LaunchDaemon. `--provision shared-folder` is not yet
available. See ``ProvisioningMode`` for provisioning strategies and
<doc:Provisioning> for detailed guidance.

### EC2 Mac Setup

Deploy Spooktacular on AWS EC2 Mac instances to double your CI
capacity. Install Spooktacular, create VMs from IPSW, clone
configured bases, and start runners with SSH provisioning.

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
