# Provisioning Virtual Machines

Run scripts automatically when a VM boots — four strategies for different environments.

## Overview

macOS virtual machines don't have a cloud-init equivalent. Spooktacular
provides four provisioning modes to bridge this gap, each suited to
different deployment scenarios.

### Choosing a Mode

| Mode | Works without setup? | Network needed? | Best for |
|------|---------------------|----------------|----------|
| ``ProvisioningMode/diskInject`` | Yes | No | Fresh IPSW installs, CI runners |
| ``ProvisioningMode/ssh`` | Need SSH enabled | Yes | Cloned VMs with SSH |
| ``ProvisioningMode/agent`` | Need agent installed | No | OCI images |
| ``ProvisioningMode/sharedFolder`` | Need watcher | No | No-disk-modify environments |

### Disk Inject (Zero-Touch)

Before the VM boots, Spooktacular mounts the guest's data volume
and writes a standard macOS LaunchDaemon that executes your script.
This is the only mode that works on a completely vanilla macOS install.

```bash
spook create my-vm --from-ipsw latest \
    --user-data ~/setup.sh \
    --provision disk-inject
```

### SSH

After boot, Spooktacular discovers the VM's IP, connects via SSH,
and executes your script. You get real-time output streaming.

```bash
spook start my-vm \
    --user-data ~/setup.sh \
    --provision ssh \
    --ssh-user admin
```

**Requires:** Remote Login enabled in the guest
(System Settings → General → Sharing → Remote Login).

### Guest Agent

The Spooktacular guest agent communicates over VirtIO socket — a
direct host-guest channel that works without networking.

```bash
spook create my-vm --from-ipsw latest \
    --user-data ~/setup.sh \
    --provision agent
```

> Note: OCI image pull is on the roadmap. For now, use `--from-ipsw` to create VMs.

**Requires:** Agent pre-installed (included in all Spooktacular
OCI images).

### Shared Folder

The script is delivered via a VirtIO shared folder. A watcher daemon
in the guest executes new scripts automatically.

```bash
spook start my-vm \
    --user-data ~/setup.sh \
    --provision shared-folder
```

**Requires:** Watcher daemon installed in the base image.

### Kubernetes

All modes work identically from Kubernetes:

```yaml
spec:
  provisioning:
    mode: disk-inject
    userData: |
      #!/bin/bash
      echo "Provisioned by Kubernetes"
```

## Topics

### Provisioning Modes

- ``ProvisioningMode``
- ``ProvisioningMode/diskInject``
- ``ProvisioningMode/ssh``
- ``ProvisioningMode/agent``
- ``ProvisioningMode/sharedFolder``
- ``VirtualMachineSpecification``
- ``VirtualMachineBundle``
