# Provisioning Virtual Machines

Run scripts automatically when a VM boots.

## Overview

macOS virtual machines don't have a cloud-init equivalent. Spooktacular
provides provisioning modes to bridge this gap. Today, SSH provisioning
is fully working. Disk-inject is in progress, and two more modes (guest
agent and shared-folder watcher) are planned.

### Choosing a Mode

| Mode | Status | Works without setup? | Network needed? | Best for |
|------|--------|---------------------|----------------|----------|
| ``ProvisioningMode/ssh`` | **Working** | Need SSH enabled | Yes | Cloned VMs with SSH |
| ``ProvisioningMode/diskInject`` | **In progress** | Yes | No | Fresh IPSW installs, CI runners |
| ``ProvisioningMode/agent`` | Planned | Need agent installed | No | OCI images (future) |
| ``ProvisioningMode/sharedFolder`` | Planned | Need watcher | No | No-disk-modify environments |

### SSH (Working)

After boot, Spooktacular discovers the VM's IP, connects via SSH,
and executes your script. You get real-time output streaming.

```bash
spook start my-vm \
    --user-data ~/setup.sh \
    --provision ssh \
    --ssh-user admin
```

**Requires:** Remote Login enabled in the guest
(System Settings -> General -> Sharing -> Remote Login).

### Disk Inject (In Progress)

Before the VM boots, Spooktacular mounts the guest's data volume
and writes a standard macOS LaunchDaemon that executes your script.
This is the only mode that will work on a completely vanilla macOS
install. This mode is currently being implemented.

```bash
spook create my-vm --from-ipsw latest \
    --user-data ~/setup.sh \
    --provision disk-inject
```

### Guest Agent (Planned)

The Spooktacular guest agent will communicate over VirtIO socket — a
direct host-guest channel that works without networking. This mode
is planned for a future release.

### Shared Folder (Planned)

The script will be delivered via a VirtIO shared folder. A watcher
daemon in the guest will execute new scripts automatically. This
mode is planned for a future release.

## Topics

### Provisioning Modes

- ``ProvisioningMode``
- ``ProvisioningMode/diskInject``
- ``ProvisioningMode/ssh``
- ``ProvisioningMode/agent``
- ``ProvisioningMode/sharedFolder``
- ``VirtualMachineSpecification``
- ``VirtualMachineBundle``
