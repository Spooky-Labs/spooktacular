# Spooktacular Kubernetes Integration

> **Status:** Shipping. The controller runs today, reconciles `MacOSVM` and
> `RunnerPool` custom resources, and is the primary integration path for
> EC2 Mac CI fleets. For single-host use, the `spook` CLI still works
> standalone.

Run macOS virtual machines as Kubernetes resources. Each Mac host
adds 2 VM pods to your cluster (Apple's kernel limit).

## Quick Start

```bash
# 1. Install Spooktacular on each Mac (EC2 Mac, Mac mini, etc.)
brew install --cask spooktacular
sudo spook service install --bind 0.0.0.0:9470

# 2. Install the operator in your K8s cluster
kubectl apply -f https://spooktacular.dev/k8s/crds/macosvm.yaml
helm install spooktacular-operator spooktacular/operator \
  --set nodes[0].host=10.0.1.50:9470 \
  --set nodes[0].token=$(ssh ec2-user@10.0.1.50 'cat ~/.spooktacular/api-token')

# 3. Create a VM
kubectl apply -f vm.yaml
```

## Custom Resources

### MacOSVM

A single macOS virtual machine.

```yaml
apiVersion: spooktacular.io/v1alpha1
kind: MacOSVM
metadata:
  name: ci-runner-01
  namespace: ci
spec:
  # Image source (required — choose one):
  image: ghcr.io/spooktacular/macos-xcode:15.4-16.2   # OCI image
  # fromIPSW: latest                                    # or IPSW

  # Hardware resources:
  resources:
    cpu: 4           # cores (minimum 4)
    memory: 8Gi      # RAM
    disk: 64Gi       # disk image size (APFS sparse)

  # Display:
  displays: 1        # 1 or 2 virtual displays

  # Network:
  network:
    mode: nat        # nat | bridged | isolated | host-only
    # interface: en0 # required for bridged mode

  # Shared folders:
  sharedFolders:
    - hostPath: /data/training
      guestTag: training-data
      readOnly: true

  # User-data provisioning:
  provisioning:
    mode: disk-inject   # see "Provisioning Modes" below
    userData: |
      #!/bin/bash
      echo "Hello from first boot!"
      # Install tools, configure runners, etc.
    sshUser: admin           # for mode: ssh
    sshKeySecret: ssh-key    # K8s Secret name, for mode: ssh

  # Node placement:
  node: mac-mini-01          # pin to specific Mac (optional)

status:
  phase: Running             # Pending | Creating | Installing | Provisioning | Running | Stopped | Failed
  ip: 192.168.64.3
  node: mac-mini-01
  conditions:
    - type: Ready
      status: "True"
```

### MacOSVMPool

A managed pool of ephemeral VMs with auto-replacement.

```yaml
apiVersion: spooktacular.io/v1alpha1
kind: MacOSVMPool
metadata:
  name: ci-runners
spec:
  replicas: 2                # VMs per host (max 2)
  image: ghcr.io/spooktacular/macos-xcode:15.4-16.2

  template: github-runner    # built-in template
  templateArgs:
    repo: myorg/myrepo
    token: ghp_xxxxxxxxxxxx
    labels: macos,arm64,xcode16

  ephemeral: true            # destroy + recreate after each job

  provisioning:
    mode: agent              # recommended for OCI images
    userData: ""             # template handles the script

  scaling:
    minReplicas: 0
    maxReplicas: 2           # per host (kernel limit)
    idleTimeout: 5m          # scale down after 5 min idle
```

## Provisioning Modes

When you specify `provisioning.userData`, you must choose how
Spooktacular executes the script inside the VM. The modes are
identical across `kubectl`, the `spook` CLI, and the GUI.

### `disk-inject` — Zero-Touch Provisioning

```yaml
provisioning:
  mode: disk-inject
  userData: |
    #!/bin/bash
    echo "Runs on first boot, no setup required"
```

Your script runs automatically when macOS starts. Before the VM
boots, Spooktacular writes a standard macOS LaunchDaemon to the
guest's disk that executes your script at startup.

**Works with:** Any macOS image, including vanilla IPSW installs.
No SSH, no agent, no network required.

**Best for:** Fresh VMs from IPSW, CI runners, zero-touch fleet
provisioning.

### `ssh` — SSH Execution

```yaml
provisioning:
  mode: ssh
  sshUser: admin
  sshKeySecret: my-ssh-key   # K8s Secret with private key
  userData: |
    #!/bin/bash
    echo "Runs via SSH after boot"
```

Spooktacular waits for the VM to boot, discovers its IP, connects
via SSH, and runs your script. Real-time output streaming.

**Works with:** VMs where Remote Login (SSH) is enabled in the
guest. Typically cloned from a base image with SSH configured.

**Best for:** Development workflows, debugging, interactive use.

### `agent` — Guest Agent (vsock)

```yaml
provisioning:
  mode: agent
  userData: |
    #!/bin/bash
    echo "Runs via guest agent, no network needed"
```

The Spooktacular guest agent runs inside the VM and communicates
with the host over a VirtIO socket — a direct channel that works
without any networking. Fastest provisioning mode.

**Works with:** VMs from Spooktacular's OCI images
(`ghcr.io/spooktacular/`), which include the agent.

**Best for:** CI/CD runners, ML workloads, isolated builds.

### `shared-folder` — Shared Folder Delivery

```yaml
provisioning:
  mode: shared-folder
  userData: |
    #!/bin/bash
    echo "Delivered via shared folder, run by watcher"
```

The script is placed on a VirtIO shared folder. A watcher daemon
in the guest detects and executes it. No networking required.

**Works with:** VMs that have the shared-folder watcher installed
(included in Spooktacular OCI images).

**Best for:** Environments where you can't modify the guest disk
and SSH isn't available.

## EC2 Mac Setup

Double your CI capacity on AWS EC2 Mac dedicated hosts.

```bash
# One-liner setup on an EC2 Mac:
curl -sSL https://spooktacular.dev/ec2-setup.sh | bash -s -- \
  --github-repo myorg/myrepo \
  --github-token ghp_xxx \
  --xcode 16.2

# Result: 2 GitHub Actions runners on one EC2 Mac.
# Before: 1 EC2 Mac = 1 runner. After: 1 EC2 Mac = 2 runners.
```

### Scaling

| EC2 Macs | Runners (before) | Runners (after) | Cost savings |
|----------|------------------|-----------------|--------------|
| 5        | 5                | 10              | 50%          |
| 10       | 10               | 20              | 50%          |
| 20       | 20               | 40              | 50%          |

## Node Configuration

Each Mac running Spooktacular is a "node" in the operator's
registry. Configure via Helm values or a ConfigMap:

```yaml
# values.yaml
nodes:
  - host: 10.0.1.50:9470
    token: <api-token>
    labels:
      xcode: "16.2"
      chip: "m2-pro"
  - host: 10.0.1.51:9470
    token: <api-token>
    labels:
      xcode: "16.2"
      chip: "m4"
```

The operator schedules VMs onto nodes respecting the 2-VM kernel
limit. Use `spec.node` to pin a VM to a specific Mac, or let the
scheduler choose (round-robin, capacity-aware).
