# Configuring Jenkins Nodes

Run Jenkins build agents in Spooktacular VMs for iOS and macOS CI/CD.

## Overview

Jenkins can use Spooktacular VMs as build agents. Each Mac runs
2 VMs, each VM runs a Jenkins agent — doubling your Mac CI capacity.

## Prerequisites

- Apple Silicon Mac with Spooktacular installed
- Jenkins controller (runs on any OS)
- SSH connectivity between Jenkins controller and Mac host
- A base VM with Xcode and the Jenkins agent installed

## Creating a Base Image

```bash
# Create the base VM
spook create jenkins-base --from-ipsw latest

# Install Xcode and Jenkins agent in the base VM
# (Use SSH after the VM boots, or disk-inject provisioning)
spook start jenkins-base
spook ssh jenkins-base

# Inside the VM:
# 1. Install Xcode from the App Store or xcode-select
# 2. Download the Jenkins agent .jar from your Jenkins controller
# 3. Create a LaunchAgent to start the agent on boot
```

## Provisioning Script

Create a provisioning script that registers the VM as a Jenkins agent:

```bash
#!/bin/bash
# jenkins-agent-setup.sh

JENKINS_URL="https://jenkins.example.com"
AGENT_NAME="$(hostname)"
AGENT_SECRET="YOUR_AGENT_SECRET"

# Download the agent .jar
curl -sO "$JENKINS_URL/jnlpJars/agent.jar"

# Start the agent
java -jar agent.jar \
  -url "$JENKINS_URL" \
  -secret "$AGENT_SECRET" \
  -name "$AGENT_NAME" \
  -workDir "/Users/admin/jenkins"
```

## Clone and Start Agents

```bash
# Clone the base image for each agent
spook clone jenkins-base jenkins-agent-01
spook clone jenkins-base jenkins-agent-02

# Start with the provisioning script
spook start jenkins-agent-01 --headless \
  --user-data ./jenkins-agent-setup.sh --provision ssh

spook start jenkins-agent-02 --headless \
  --user-data ./jenkins-agent-setup.sh --provision ssh
```

## Ephemeral Agents

For clean builds every time, use ephemeral mode. The VM is
destroyed after the agent disconnects:

```bash
spook start jenkins-agent-01 --headless --ephemeral \
  --user-data ./jenkins-agent-setup.sh --provision ssh
```

Combine with a cron job or Jenkins pipeline that re-clones
and re-starts agents between builds.

## Running as a Service

For persistent agents that survive Mac reboots:

```bash
sudo spook service install jenkins-agent-01
sudo spook service install jenkins-agent-02
```

## Kubernetes Integration

If your Jenkins runs on Kubernetes, use the Spooktacular
Kubernetes operator to manage agents declaratively:

```yaml
apiVersion: spooktacular.app/v1alpha1
kind: MacOSVM
metadata:
  name: jenkins-agent-01
spec:
  sourceVM: jenkins-base
  cpu: 4
  memoryInGigabytes: 8
  provisioning:
    mode: ssh
    script: |
      #!/bin/bash
      curl -sO https://jenkins.example.com/jnlpJars/agent.jar
      java -jar agent.jar -url https://jenkins.example.com \
        -secret $AGENT_SECRET -name $(hostname) -workDir /tmp/jenkins
```

## Topics

### Related Guides

- <doc:GettingStarted>
- <doc:CLIReference>
- <doc:KubernetesGuide>

### Key Types

- ``VirtualMachineSpecification``
- ``ProvisioningMode``
- ``SSHExecutor``
