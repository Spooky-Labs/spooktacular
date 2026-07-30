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
| ``ProvisioningMode/diskInject`` | **Working** | Yes | No | Fresh installs, CI runners |
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

### Disk Inject (Working)

A standard macOS LaunchDaemon is written into the guest disk as
`root:wheel`, and it runs your script on first boot. This is the only
mode that works on a completely vanilla macOS install, because it needs
nothing enabled in the guest and no guest networking at all.

The write happens once, into the **shared base image**, at base-build
time — not per VM. That is why it is also the only privileged step in
the system, and why it costs nothing on the second and every later
create. See <doc:InstantCreate>.

```bash
spook create my-vm --user-data ~/setup.sh --provision disk-inject
```

The guest reports the script's exit code back to the host over vsock,
so `spook start` prints a definitive result instead of polling for a
service and guessing from a timeout. When a script fails, its output is
in the VM bundle's `provision/` directory.

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
