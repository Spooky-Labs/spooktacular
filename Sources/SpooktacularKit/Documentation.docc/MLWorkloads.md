# Machine Learning Workloads

Run ML training and inference on Apple Silicon GPUs inside Spooktacular virtual machines.

## Overview

Apple Silicon's unified memory architecture gives every Mac direct
access to a powerful GPU and Neural Engine without a discrete graphics
card. Spooktacular VMs expose these capabilities to guest macOS,
making it possible to run GPU-accelerated machine learning workloads
inside isolated virtual machines.

### Why macOS VMs for ML?

- **Apple Silicon GPU** — Metal-accelerated training via MLX, PyTorch
  MPS, and Create ML
- **Neural Engine** — 16-core (or more) Neural Engine for Core ML
  inference
- **Unified memory** — GPU and CPU share the same memory pool, so
  there is no PCIe bottleneck for large models
- **Reproducible environments** — Clone a configured ML VM instantly
  with ``CloneManager`` for reproducible experiments
- **Isolation** — Run multiple experiments concurrently without
  dependency conflicts between VMs

## Hardware Configuration for ML

ML workloads benefit from maximum CPU, memory, and disk allocation.
Allocate resources according to your workload:

### Single-VM Configuration (Dedicated Host)

When the entire host is dedicated to one ML workload:

```bash
spook create ml-trainer \
    --cpu 8 --memory 24 --disk 200 \
    --network host-only \
    --disable-audio
```

### Dual-VM Configuration (Shared Host)

When running two ML VMs on one host (e.g., training + inference):

```bash
# Training VM — more CPU and memory
spook create ml-train \
    --cpu 6 --memory 16 --disk 200 \
    --network host-only \
    --disable-audio

# Inference VM — lighter resources
spook create ml-serve \
    --cpu 4 --memory 8 --disk 64 \
    --network nat \
    --disable-audio
```

### Recommended Specs by Chip

| Chip | Cores | RAM | Single ML VM | Dual ML VMs |
|------|-------|-----|-------------|-------------|
| M1 | 8 | 16 GB | 6 CPU / 12 GB | 4+4 CPU / 6+6 GB |
| M2 Pro | 12 | 32 GB | 10 CPU / 24 GB | 6+6 CPU / 14+14 GB |
| M2 Max | 12 | 64 GB | 10 CPU / 48 GB | 6+6 CPU / 28+28 GB |
| M2 Ultra | 24 | 192 GB | 20 CPU / 160 GB | 12+12 CPU / 80+80 GB |
| M4 | 10 | 32 GB | 8 CPU / 24 GB | 4+4 CPU / 12+12 GB |

> Note: Always leave at least 2 CPU cores and 4 GB RAM for the host
> macOS. The minimum VM CPU count is 4 (see ``VirtualMachineSpecification/minimumCPUCount``).

## Metal GPU Access in VMs

The Virtualization framework provides GPU access to macOS guests via
`VZMacGraphicsDeviceConfiguration`. This is configured automatically
when you create a VM with Spooktacular — every VM gets a virtual
GPU device backed by the host's Metal-capable hardware.

### How It Works

When ``VirtualMachineConfiguration/applySpec(_:to:)`` configures a VM, it
creates a `VZMacGraphicsDeviceConfiguration` with one or two virtual
displays. The guest macOS sees this as a standard Metal GPU and can
run any Metal workload: shaders, compute kernels, ML frameworks.

```swift
// This happens automatically inside VMConfiguration.applySpec
let graphics = VZMacGraphicsDeviceConfiguration()
graphics.displays = [
    VZMacGraphicsDisplayConfiguration(
        widthInPixels: 1920,
        heightInPixels: 1200,
        pixelsPerInch: 80
    )
]
configuration.graphicsDevices = [graphics]
```

### Verifying GPU Access Inside the VM

```bash
# Check Metal device availability
spook exec ml-trainer -- system_profiler SPDisplaysDataType

# Run a quick Metal compute test
spook exec ml-trainer -- python3 -c "
import mlx.core as mx
a = mx.ones((1000, 1000))
b = mx.ones((1000, 1000))
c = a @ b
print(f'Matrix multiply result shape: {c.shape}')
print(f'GPU computation successful')
"
```

### Headless GPU Mode

For ML workloads you typically do not need a visible display
window. Run headless to avoid unnecessary display overhead:

```bash
spook start ml-trainer --headless
```

The virtual GPU is still fully functional for compute workloads
even in headless mode. Display rendering simply has no visible
output target.

## Shared Folders for Datasets

Large datasets (often many gigabytes or terabytes) should not be
copied into each VM's disk image. Instead, use VirtIO shared
folders to mount host directories directly inside the guest.

### Mounting Datasets

```bash
# Share a dataset directory (read-only) and an output directory (read-write)
spook share ml-trainer add /data/imagenet --tag imagenet --read-only
spook share ml-trainer add /data/checkpoints --tag checkpoints
```

Inside the guest, the first shared folder appears automatically in
Finder (macOS automount). Additional folders can be mounted manually:

```bash
# Inside the guest VM
sudo mkdir -p /Volumes/imagenet /Volumes/checkpoints
sudo mount_virtiofs imagenet /Volumes/imagenet
sudo mount_virtiofs checkpoints /Volumes/checkpoints
```

### Kubernetes Configuration

```yaml
apiVersion: spooktacular.io/v1alpha1
kind: MacOSVM
metadata:
  name: ml-trainer
spec:
  image: ghcr.io/spooktacular/macos-ml:15.4
  resources:
    cpu: 8
    memory: 24Gi
    disk: 100Gi
  sharedFolders:
    - hostPath: /data/imagenet
      guestTag: imagenet
      readOnly: true
    - hostPath: /data/checkpoints
      guestTag: checkpoints
      readOnly: false
  provisioning:
    mode: agent
    userData: |
      #!/bin/bash
      mkdir -p /Volumes/imagenet /Volumes/checkpoints
      mount_virtiofs imagenet /Volumes/imagenet
      mount_virtiofs checkpoints /Volumes/checkpoints
      cd /Volumes/imagenet && python3 /opt/train.py
```

See ``SharedFolder`` for the API details and ``VirtualMachineSpecification/sharedFolders``
for how shared folders are configured in the VM specification.

## MLX Framework

[MLX](https://github.com/ml-explore/mlx) is Apple's array framework
for machine learning on Apple Silicon. It runs natively on the Metal
GPU and is designed for the unified memory architecture.

### Installing MLX in a VM

```bash
# Via the provisioning user-data script
spook create ml-trainer --from-ipsw latest \
    --cpu 8 --memory 24 --disk 100 \
    --user-data ~/setup-mlx.sh \
    --provision disk-inject
```

Where `setup-mlx.sh`:

```bash
#!/bin/bash
set -euo pipefail

# Install Python and MLX
/opt/homebrew/bin/brew install python@3.12
pip3 install mlx mlx-lm numpy

# Verify installation
python3 -c "import mlx.core as mx; print(f'MLX default device: {mx.default_device()}')"
```

### MLX Training Example

```python
# train_mlx.py — runs inside the VM
import mlx.core as mx
import mlx.nn as nn
import mlx.optimizers as optim

class SimpleModel(nn.Module):
    def __init__(self):
        super().__init__()
        self.layers = [
            nn.Linear(784, 256),
            nn.Linear(256, 128),
            nn.Linear(128, 10),
        ]

    def __call__(self, x):
        for l in self.layers[:-1]:
            x = nn.relu(l(x))
        return self.layers[-1](x)

model = SimpleModel()
optimizer = optim.Adam(learning_rate=1e-3)

# Training loop
for epoch in range(10):
    # ... load data from /Volumes/training-data
    loss = train_step(model, optimizer, batch)
    mx.eval(loss)
    print(f"Epoch {epoch}: loss = {loss.item():.4f}")

# Save checkpoint to shared folder
mx.savez("/Volumes/checkpoints/model.npz", **dict(model.parameters()))
```

### MLX-LM for Language Models

Fine-tune or run inference on language models:

```bash
# Inside the VM
pip3 install mlx-lm

# Download and convert a model
python3 -m mlx_lm.convert --hf-path mistralai/Mistral-7B-v0.1

# Run inference
python3 -m mlx_lm.generate --model mlx_model --prompt "Hello, world"

# Fine-tune with LoRA
python3 -m mlx_lm.lora --model mlx_model \
    --data /Volumes/training-data/finetune.jsonl \
    --output /Volumes/checkpoints/lora-adapters
```

## PyTorch with MPS Backend

PyTorch supports Apple Silicon GPU acceleration via the MPS
(Metal Performance Shaders) backend.

### Installation

```bash
#!/bin/bash
# setup-pytorch.sh
pip3 install torch torchvision torchaudio
```

### Verifying MPS Availability

```python
import torch

print(f"MPS available: {torch.backends.mps.is_available()}")
print(f"MPS built: {torch.backends.mps.is_built()}")

device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
print(f"Using device: {device}")

# Quick benchmark
x = torch.randn(1000, 1000, device=device)
y = torch.randn(1000, 1000, device=device)
z = x @ y
print(f"Matrix multiply on {device}: {z.shape}")
```

### PyTorch Training Example

```python
# train_pytorch.py
import torch
import torch.nn as nn
import torchvision
import torchvision.transforms as transforms

device = torch.device("mps")

# Load data from shared folder
transform = transforms.Compose([
    transforms.ToTensor(),
    transforms.Normalize((0.5,), (0.5,))
])

trainset = torchvision.datasets.CIFAR10(
    root="/Volumes/training-data", train=True,
    download=False, transform=transform
)
trainloader = torch.utils.data.DataLoader(
    trainset, batch_size=64, shuffle=True
)

# Simple CNN
model = torchvision.models.resnet18(num_classes=10).to(device)
optimizer = torch.optim.Adam(model.parameters(), lr=1e-3)
criterion = nn.CrossEntropyLoss()

for epoch in range(10):
    running_loss = 0.0
    for images, labels in trainloader:
        images, labels = images.to(device), labels.to(device)
        optimizer.zero_grad()
        outputs = model(images)
        loss = criterion(outputs, labels)
        loss.backward()
        optimizer.step()
        running_loss += loss.item()

    avg_loss = running_loss / len(trainloader)
    print(f"Epoch {epoch}: loss = {avg_loss:.4f}")

    # Save checkpoint to shared folder
    torch.save(model.state_dict(), f"/Volumes/checkpoints/epoch_{epoch}.pt")
```

## Core ML and Create ML

### Create ML Training in a VM

```bash
# Inside the VM — train an image classifier
swift -e '
import CreateML
import Foundation

let data = try MLImageClassifier.DataSource.labeledDirectories(
    at: URL(fileURLWithPath: "/Volumes/training-data/images")
)
let classifier = try MLImageClassifier(trainingData: data)
try classifier.write(to: URL(fileURLWithPath: "/Volumes/checkpoints/Classifier.mlmodel"))
print("Model saved successfully")
'
```

### Core ML Inference

```python
# inference.py — run a Core ML model inside the VM
import coremltools as ct
import numpy as np

model = ct.models.MLModel("/Volumes/checkpoints/Classifier.mlmodel")
prediction = model.predict({"image": input_image})
print(f"Prediction: {prediction}")
```

## Federated Learning Setup

Run multiple isolated VMs that each train on a subset of data,
then aggregate the results. Host-only networking allows the VMs
to communicate with each other without external network access.

### Architecture

```
+-----------------------------------------+
|  Mac Host                               |
|  +----------+  +----------+            |
|  |  VM-1    |  |  VM-2    |            |
|  |  Worker  |<>|  Worker  |            |
|  |  Shard 1 |  |  Shard 2 |            |
|  +----------+  +----------+            |
|       ^              ^                  |
|       +------+-------+                  |
|         Host-only network               |
|              |                          |
|      +-------v--------+                |
|      |  Aggregator    |                |
|      |  (host script) |                |
|      +----------------+                |
+-----------------------------------------+
```

### Setup

```bash
# Create two worker VMs with host-only networking
spook create worker-01 --cpu 4 --memory 8 --disk 64 \
    --network host-only --disable-audio

spook create worker-02 --cpu 4 --memory 8 --disk 64 \
    --network host-only --disable-audio

# Share different data shards with each
spook share worker-01 add /data/shard-01 --tag data --read-only
spook share worker-02 add /data/shard-02 --tag data --read-only

# Share a common output directory
spook share worker-01 add /data/federated-output --tag output
spook share worker-02 add /data/federated-output --tag output

# Start both
spook start worker-01 --headless
spook start worker-02 --headless
```

The ``NetworkMode/hostOnly`` mode is intended to let VMs communicate
with each other and the host over a private network without external
internet access -- ideal for secure ML training environments.

> Important: Host-only networking currently falls back to NAT mode.
> VMs will have internet access until a future release adds true
> host-only isolation. Plan your network security accordingly.

## Training Checkpoints via VM Snapshots

Save a disk-level snapshot before long-running training operations.
If something goes wrong, restore the disk to the pre-training state:

```bash
# Stop the VM and snapshot before a long training run
spook stop ml-trainer
spook snapshot ml-trainer pre-training
spook start ml-trainer --headless

# Start training
spook exec ml-trainer -- python3 /opt/train.py --epochs 100

# If something goes wrong, stop and restore
spook stop ml-trainer
spook restore ml-trainer pre-training
spook start ml-trainer --headless

# After successful training, stop and snapshot the trained state
spook stop ml-trainer
spook snapshot ml-trainer trained-v1
```

Disk-level snapshots copy `disk.img` and `auxiliary.bin`. The VM
must be stopped before saving or restoring. Combine with
application-level checkpointing (saving model weights to shared
folders) for the best recovery story.

## Inference Server Deployment

Deploy a trained model as an inference server accessible on the
network:

### NAT Mode (Port Forwarding)

```bash
spook create inference-server --from-ipsw latest \
    --cpu 4 --memory 8 --disk 64 \
    --network nat \
    --user-data ~/setup-inference.sh \
    --provision disk-inject
```

### Bridged Mode (Own LAN IP)

For production inference servers that need their own IP address
on the local network:

```bash
spook create inference-server --from-ipsw latest \
    --cpu 4 --memory 8 --disk 64 \
    --network bridged:en0 \
    --user-data ~/setup-inference.sh \
    --provision disk-inject
```

The ``NetworkMode/bridged(interface:)`` mode gives the VM its own
DHCP-assigned IP on the host's LAN, making it directly addressable
by other machines.

> Note: Bridged networking requires the `com.apple.vm.networking`
> entitlement. See ``NetworkMode`` for details.

### Inference Server Script

```bash
#!/bin/bash
# setup-inference.sh
set -euo pipefail

# Mount the model from a shared folder
mkdir -p /Volumes/models
mount_virtiofs models /Volumes/models

# Install dependencies
pip3 install flask mlx mlx-lm

# Start the inference server
cat > /opt/serve.py << 'PYEOF'
from flask import Flask, request, jsonify
from mlx_lm import load, generate

app = Flask(__name__)
model, tokenizer = load("/Volumes/models/my-model")

@app.route("/predict", methods=["POST"])
def predict():
    prompt = request.json["prompt"]
    response = generate(model, tokenizer, prompt=prompt, max_tokens=256)
    return jsonify({"response": response})

app.run(host="0.0.0.0", port=8080)
PYEOF

python3 /opt/serve.py
```

## Performance Tuning Tips

### Memory Management

- **Allocate maximum memory** — Unified memory is shared between
  CPU and GPU. More VM memory means more GPU memory for large
  models.
- **Avoid swap** — If the VM runs out of memory, macOS will swap
  to the virtual disk, which drastically reduces performance.
  Size your VMs with enough RAM for your workload.

### Disk I/O

- **Use shared folders for datasets** — VirtIO shared folders
  bypass the virtual disk layer, providing direct host filesystem
  access.
- **SSD-backed hosts** — Apple Silicon Macs have fast NVMe storage.
  APFS sparse disk images benefit from the underlying SSD speed.
- **Pre-stage data** — Copy frequently accessed data to the VM's
  local disk for maximum I/O performance during training.

### GPU Utilization

- **Profile with Metal System Trace** — Use Instruments in Xcode
  to profile GPU utilization inside the VM.
- **Batch sizes** — Larger batch sizes improve GPU utilization but
  require more memory. Find the largest batch size that fits.
- **Avoid CPU-GPU transfers** — With unified memory, data stays
  in place. But framework-level copies can still occur. Use
  in-place operations when possible.

### Network

- **Host-only for isolation** — ``NetworkMode/hostOnly`` eliminates
  network overhead from external traffic.
- **Shared folders over network mounts** — VirtIO shared folders
  are faster than NFS or SMB mounts for data access.

## Example: Training a Model with Shared Data

A complete end-to-end example:

```bash
# 1. Prepare the host
mkdir -p /data/cifar10 /data/models

# Download CIFAR-10 to the host
python3 -c "
import torchvision
torchvision.datasets.CIFAR10('/data/cifar10', download=True)
"

# 2. Create the ML VM
spook create ml-cifar \
    --from-ipsw latest \
    --cpu 6 --memory 16 --disk 64 \
    --network host-only \
    --disable-audio \
    --user-data /opt/spooktacular/train-cifar.sh \
    --provision disk-inject

# 3. Add shared folders
spook share ml-cifar add /data/cifar10 --tag data --read-only
spook share ml-cifar add /data/models --tag models

# 4. Start training
spook start ml-cifar --headless

# 5. Monitor progress
spook exec ml-cifar -- tail -f /tmp/training.log

# 6. Results appear in /data/models/ on the host
ls /data/models/
# epoch_0.pt  epoch_1.pt  ...  final_model.pt
```

## Topics

### Related Guides

- <doc:GettingStarted>
- <doc:Provisioning>
- <doc:KubernetesGuide>
- <doc:RemoteDesktop>

### Key Types

- ``VirtualMachineSpecification``
- ``VirtualMachineConfiguration``
- ``SharedFolder``
- ``NetworkMode``
- ``CloneManager``
