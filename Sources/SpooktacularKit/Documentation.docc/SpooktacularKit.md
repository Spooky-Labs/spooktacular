# ``SpooktacularKit``

Create and manage macOS virtual machines on Apple Silicon.

## Overview

SpooktacularKit is the core library powering Spooktacular --- a lightweight
macOS app for running macOS virtual machines. Built on Apple's
[Virtualization](https://developer.apple.com/documentation/virtualization)
framework, it provides a Swift API for VM lifecycle management,
IPSW installation, instant APFS cloning, and enterprise provisioning.

Use SpooktacularKit directly in your Swift project, or interact with it
through the `spook` CLI, the Spooktacular GUI app, or the Kubernetes
operator. All interfaces share the same library and produce identical
behavior.

> Important: SpooktacularKit requires an Apple Silicon Mac (M1 or later)
> running macOS 14.0 (Sonoma) or later.

### Design Principles

SpooktacularKit follows Apple's Virtualization framework sample code
patterns exactly:

- Direct use of `VZVirtualMachine` --- no unnecessary abstractions
- Value types (``VirtualMachineSpecification``, ``VirtualMachineMetadata``,
  ``NetworkMode``) for all configuration
- `Sendable` conformance throughout for Swift 6 strict concurrency
- Full DocC documentation on every public API

### Creating a Virtual Machine

```swift
import SpooktacularKit

// Create a VM bundle with a hardware specification.
let spec = VirtualMachineSpecification(
    cpuCount: 8,
    memorySizeInBytes: 16 * 1024 * 1024 * 1024
)
let bundle = try VirtualMachineBundle.create(at: bundleURL, spec: spec)

// Clone the bundle instantly using APFS copy-on-write.
let clone = try CloneManager.clone(source: bundle, to: cloneURL)

// Build a Virtualization framework configuration.
let config = VZVirtualMachineConfiguration()
VirtualMachineConfiguration.applySpec(spec, to: config)
```

## Topics

### Guides

- <doc:GettingStarted>
- <doc:Provisioning>
- <doc:CLIReference>
- <doc:GitHubActionsGuide>
- <doc:JenkinsGuide>
- <doc:EC2MacDeployment>
- <doc:KubernetesGuide>
- <doc:MLWorkloads>
- <doc:RemoteDesktop>
- <doc:OpenClawGuide>
- <doc:BlueBubblesGuide>
- <doc:Versioning>

### Virtual Machine Bundles

- ``VirtualMachineBundle``
- ``VirtualMachineSpecification``
- ``VirtualMachineMetadata``
- ``SharedFolder``
- ``VirtualMachineBundleError``

### VM Lifecycle

- ``VirtualMachine``
- ``VirtualMachineState``
- ``VirtualMachineConfiguration``

### Cloning

- ``CloneManager``

### Snapshots

- ``SnapshotManager``
- ``SnapshotInfo``
- ``SnapshotError``

### IPSW Management

- ``RestoreImageManager``
- ``RestoreImageError``

### Networking

- ``NetworkMode``

### Provisioning

- ``ProvisioningMode``

### Compatibility

- ``Compatibility``

### Image Library

- ``ImageLibrary``
- ``VirtualMachineImage``
- ``ImageSource``

### Setup Automation

- ``SetupAutomation``
- ``SetupAutomationExecutor``
- ``SetupAutomationExecutorError``
- ``BootStep``
- ``BootAction``
- ``KeyCode``
- ``Modifier``

### Templates

- ``GitHubRunnerTemplate``
- ``RemoteDesktopTemplate``
- ``OpenClawTemplate``
- ``ScriptFile``

### Capacity

- ``CapacityCheck``
- ``CapacityError``

### Process Management

- ``PIDFile``

### Networking Utilities

- ``IPResolver``
- ``SSHExecutor``
- ``SSHError``

### Logging

- ``Log``

### Accessibility

- ``AccessibilityID``
