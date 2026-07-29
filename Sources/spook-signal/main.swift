import Foundation

// Guest-side readiness reporter.
//
// Baked into the macOS base image beside the provisioner LaunchDaemon
// and invoked as the last line of `spook-provision-runner.sh`. It opens
// an AF_VSOCK connection to the host (CID 2) on port 9470 and writes a
// five-byte frame: 'S' followed by the first-boot exit code, big-endian.
//
// This exists so the host learns that provisioning finished by being
// told, rather than by polling for an IP and then for a service — the
// timing race the project forbids. It is deliberately tiny: no
// dependencies, no retries beyond one connect attempt, and a silent
// non-zero exit when the host is not listening, because the runner
// script treats a failed signal as non-fatal.
//
// Usage: spook-signal <exit-code>

/// The vsock port the host's `ProvisioningSignalListener` monitors.
/// Must match `ProvisioningSignalListener.listenerPort`.
let readinessPort: UInt32 = 9470

/// Frame marker (`'S'`), matching `ProvisioningSignal`.
let frameMagic: UInt8 = 0x53

let exitCode = Int32(CommandLine.arguments.dropFirst().first ?? "0") ?? 0

let descriptor = socket(AF_VSOCK, SOCK_STREAM, 0)
guard descriptor >= 0 else { exit(1) }
defer { close(descriptor) }

var address = sockaddr_vm()
address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
address.svm_family = sa_family_t(AF_VSOCK)
address.svm_port = readinessPort
address.svm_cid = UInt32(bitPattern: VMADDR_CID_HOST)

let connected = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
        connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_vm>.size))
    }
}
guard connected == 0 else { exit(1) }

var frame = [frameMagic]
withUnsafeBytes(of: exitCode.bigEndian) { frame.append(contentsOf: $0) }
let written = frame.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
exit(written == frame.count ? 0 : 1)
