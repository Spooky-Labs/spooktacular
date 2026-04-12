# ``SpooktacularKit``

Create and manage macOS virtual machines on Apple Silicon.

## Overview

SpooktacularKit is the core library powering Spooktacular — a lightweight
macOS app for running macOS virtual machines. Built directly on Apple's
[Virtualization](https://developer.apple.com/documentation/virtualization)
framework, it provides a clean Swift API for VM lifecycle management,
IPSW installation, instant APFS cloning, and enterprise provisioning.

### Design Philosophy

SpooktacularKit follows Apple's sample code patterns exactly:

- Direct use of `VZVirtualMachine` — no unnecessary abstractions
- Value types (`VMSpec`, `VMMetadata`, `NetworkMode`) for all configuration
- `Sendable` conformance throughout for Swift 6 strict concurrency
- Full DocC documentation on every public API

### Quick Start

```swift
// Create a VM bundle
let spec = VMSpec(cpuCount: 8, memorySizeInBytes: 16_000_000_000)
let bundle = try VMBundle.create(at: bundleURL, spec: spec)

// Clone it instantly (APFS copy-on-write)
let clone = try CloneManager.clone(source: bundle, to: cloneURL)

// Build a Virtualization framework configuration
let config = VZVirtualMachineConfiguration()
VMConfiguration.applySpec(spec, to: config)
```

## Topics

### Virtual Machine Bundles

- ``VMBundle``
- ``VMSpec``
- ``VMMetadata``
- ``SharedFolder``
- ``VMBundleError``

### VM Lifecycle

- ``VirtualMachine``
- ``VMState``
- ``VMConfiguration``

### Cloning

- ``CloneManager``

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
- ``VMImage``
- ``ImageSource``

### Accessibility

- ``AccessibilityID``
