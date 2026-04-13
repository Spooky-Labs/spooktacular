# Running OpenClaw in Virtual Machines

Run two isolated OpenClaw AI agent instances on a single Mac — each with its own workspace, channels, and API keys.

## Overview

[OpenClaw](https://openclaw.ai) is an open-source self-hosted AI assistant
that connects to Claude, GPT-4, Gemini, and other models. Running OpenClaw
in macOS VMs with Spooktacular gives you:

- **Isolation** — each instance has its own macOS environment, API keys,
  and workspace. A misconfigured agent can't affect the other.
- **2 instances per Mac** — Apple Silicon's 2-VM kernel limit maps
  perfectly to running a pair of agents (e.g., work + personal,
  or production + staging).
- **Snapshots** — save a working OpenClaw configuration, experiment,
  and roll back if something breaks.
- **Kubernetes-managed** — scale OpenClaw instances across a fleet
  of Macs using ``MacOSVMPool``.

### Prerequisites

- Apple Silicon Mac (M1 or later)
- macOS 14+ on the host
- Spooktacular installed (`brew install --cask spooktacular`)
- API key from Anthropic, OpenAI, or Google

## Quick Start: Two OpenClaw Instances

### 1. Create the first VM

```bash
spook create openclaw-work --from-ipsw latest \
    --cpu 4 --memory 8 --disk 32 \
    --network nat \
    --user-data ./setup-openclaw.sh \
    --provision disk-inject
```

### 2. Clone for the second instance

```bash
spook clone openclaw-work openclaw-personal
```

The clone takes ~50ms (APFS copy-on-write). Each VM gets a
unique machine identifier automatically.

### 3. Start both

```bash
spook start openclaw-work --headless
spook start openclaw-personal --headless
```

Both VMs boot and run OpenClaw independently. Each listens
on its own IP address, port 18789.

### 4. Check status

```bash
spook list
spook ip openclaw-work
spook ip openclaw-personal
```

## User-Data Script for OpenClaw

Create a script that installs and configures OpenClaw automatically:

```bash
#!/bin/bash
# setup-openclaw.sh — installs OpenClaw in a macOS VM

set -euo pipefail

# Install Homebrew (if not present)
if ! command -v brew &>/dev/null; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Install Node.js 24
brew install node@24
echo 'export PATH="/opt/homebrew/opt/node@24/bin:$PATH"' >> ~/.zshrc
export PATH="/opt/homebrew/opt/node@24/bin:$PATH"

# Install OpenClaw
npm install -g openclaw@latest

# Run onboard with daemon installation
# (The API key should be set via environment variable or
#  injected via the shared folder)
openclaw onboard --install-daemon

echo "OpenClaw installed and running on port 18789"
```

> Note: For production deployments, pass the API key via
> a shared folder or environment variable rather than
> hardcoding it in the script.

### Passing API Keys Securely

Use a shared folder to deliver configuration without
embedding secrets in the script:

```bash
# On the host: create a config directory
mkdir -p ~/openclaw-configs/work
cat > ~/openclaw-configs/work/openclaw.json << 'EOF'
{
    "model": "claude-sonnet-4-5-20250514",
    "anthropicApiKey": "sk-ant-your-key-here"
}
EOF

# Create VM with shared folder
spook create openclaw-work --from-ipsw latest \
    --share ~/openclaw-configs/work:config:ro \
    --user-data ./setup-openclaw.sh
```

In the setup script, copy the config from the shared folder:

```bash
# Inside setup-openclaw.sh
mkdir -p ~/.openclaw
cp "/Volumes/My Shared Files/openclaw.json" ~/.openclaw/openclaw.json
openclaw config validate
```

## Kubernetes: OpenClaw Fleet

Deploy OpenClaw instances across multiple Macs using
the Kubernetes operator:

```yaml
apiVersion: spooktacular.io/v1alpha1
kind: MacOSVMPool
metadata:
  name: openclaw-agents
  namespace: ai
spec:
  replicas: 2
  image: ghcr.io/spooktacular/macos:15.4

  provisioning:
    mode: disk-inject
    userData: |
      #!/bin/bash
      brew install node@24
      export PATH="/opt/homebrew/opt/node@24/bin:$PATH"
      npm install -g openclaw@latest
      mkdir -p ~/.openclaw
      # Config injected via K8s secret → shared folder
      cp "/Volumes/My Shared Files/openclaw.json" ~/.openclaw/
      openclaw onboard --install-daemon

  resources:
    cpu: 4
    memory: 8Gi
    disk: 32Gi

  network:
    mode: nat
```

Each Mac in the fleet runs 2 OpenClaw VMs. Ten Macs =
20 OpenClaw instances.

## Networking Between Instances

If your OpenClaw instances need to communicate (e.g.,
a coordinator agent delegating to worker agents):

```bash
spook create openclaw-coordinator --from-ipsw latest --network nat
spook create openclaw-worker --from-ipsw latest --network nat
```

NAT networking lets the VMs reach each other via their
DHCP-assigned IPs and the host Mac. The coordinator can
reach the worker's gateway on port 18789. Use
``NetworkMode/isolated`` if you need to prevent internet
access entirely, communicating through shared folders
and the VirtIO socket instead.

For internet access + inter-VM communication, use
NAT networking — both VMs can reach each other via
their NAT-assigned IPs.

## Resource Planning

| Setup | CPU | Memory | Disk | Notes |
|-------|-----|--------|------|-------|
| Cloud models only | 4 cores | 4 GB | 16 GB | Minimal — OpenClaw is lightweight |
| Cloud + light local models | 4 cores | 8 GB | 32 GB | Ollama with small models |
| Heavy local models (Llama 3) | 6 cores | 16 GB | 64 GB | Needs unified memory |

Since macOS VMs share the host's unified memory via
the Virtualization framework, the GPU (Metal) is
available inside the VM for local model inference.

## Monitoring

Check OpenClaw health in each VM:

```bash
# From the host
spook ssh openclaw-work -- "openclaw status"
spook ssh openclaw-personal -- "openclaw status"

# Or via the gateway API
curl http://$(spook ip openclaw-work):18789/health
curl http://$(spook ip openclaw-personal):18789/health
```

## Snapshots

Save a working OpenClaw configuration before making changes.
The VM must be stopped to take or restore a disk-level snapshot:

```bash
spook stop openclaw-work
spook snapshot openclaw-work pre-upgrade
spook start openclaw-work --headless
# ... make changes, install new version ...
# If something breaks:
spook stop openclaw-work
spook restore openclaw-work pre-upgrade
spook start openclaw-work --headless
```

## Topics

### Related

- ``ProvisioningMode``
- ``VirtualMachineSpecification``
- ``NetworkMode``
- ``SharedFolder``
- ``OpenClawTemplate``
