import Foundation

/// The strategy for executing a user-data script on a VM.
///
/// Each mode represents a different mechanism for delivering
/// and running a shell script inside the guest macOS. The right
/// choice depends on how the VM was created and what's available
/// in the guest.
///
/// ## Choosing a Mode
///
/// | Source | Recommended mode | Why |
/// |--------|-----------------|-----|
/// | Fresh IPSW | ``diskInject`` | Only option for vanilla macOS |
/// | OCI image (ours) | ``agent`` | Pre-installed, fastest |
/// | Clone with SSH | ``ssh`` | Most flexible |
/// | Clone without SSH | ``sharedFolder`` | No network needed |
///
/// All interfaces (CLI, GUI, K8s) expose the same modes with
/// the same descriptions.
public enum ProvisioningMode: String, Sendable, Codable, Equatable,
    Hashable, CaseIterable
{
    /// Injects a LaunchDaemon into the VM's disk before first boot.
    ///
    /// The script runs automatically when macOS starts — no SSH,
    /// no agent, no network, and no manual setup required. This is
    /// the only provisioning mode that works on a completely vanilla
    /// macOS installation from an IPSW.
    ///
    /// **How it works:** Before the VM boots, Spooktacular mounts
    /// the guest's data volume on the host and writes a standard
    /// macOS LaunchDaemon that executes your script at boot time.
    ///
    /// **Best for:** Fresh VMs created from IPSW where you need
    /// zero-touch automation — CI runners, test environments,
    /// automated fleet provisioning.
    ///
    /// **Requires:** Nothing in the guest. Works with any macOS.
    case diskInject = "disk-inject"

    /// Executes the script over SSH after the VM boots.
    ///
    /// Spooktacular waits for the VM to boot, resolves its IP
    /// address, connects via SSH, and runs your script remotely.
    /// This is the most flexible mode — you get real-time output
    /// streaming and an interactive connection.
    ///
    /// **Best for:** Cloned VMs where the base image has SSH
    /// (Remote Login) enabled. Development workflows where you
    /// want to see output as it runs.
    ///
    /// **Requires:** Remote Login (SSH) enabled in the guest.
    /// The base image must have an SSH user and either password
    /// or key-based authentication configured.
    case ssh

    /// Uses a pre-installed guest agent communicating over VirtIO socket.
    ///
    /// The Spooktacular guest agent runs inside the VM and
    /// communicates with the host over a VirtIO socket (vsock) —
    /// a direct channel that works without networking. The host
    /// pushes the script to the agent, which executes it and
    /// streams output back.
    ///
    /// **Best for:** VMs created from Spooktacular's official OCI
    /// images, which include the agent pre-installed. Fastest
    /// provisioning, works with isolated (no-network) VMs.
    ///
    /// **Requires:** The Spooktacular guest agent installed in
    /// the VM. Included in all `ghcr.io/spooktacular/` images.
    case agent

    /// Delivers the script via a VirtIO shared folder.
    ///
    /// Spooktacular shares a host directory containing your
    /// script into the VM. A LaunchDaemon in the base image
    /// watches the shared folder and executes new scripts
    /// automatically.
    ///
    /// **Best for:** Cloned VMs where SSH isn't available and
    /// you don't want to modify the disk. The base image needs
    /// a one-time setup of the watcher LaunchDaemon.
    ///
    /// **Requires:** The base image must have the shared-folder
    /// watcher LaunchDaemon installed (included in Spooktacular's
    /// OCI images, or installable via `spook tools install`).
    case sharedFolder = "shared-folder"

    // MARK: - Display Properties

    /// A short human-readable label for the mode.
    public var label: String {
        switch self {
        case .diskInject: "Zero-touch (disk inject)"
        case .ssh: "SSH"
        case .agent: "Guest agent (vsock)"
        case .sharedFolder: "Shared folder"
        }
    }

    /// A one-sentence summary for UI display.
    public var summary: String {
        switch self {
        case .diskInject:
            "Script runs automatically on first boot. No setup required."
        case .ssh:
            "Script runs over SSH after the VM boots."
        case .agent:
            "Script runs via the pre-installed guest agent over vsock."
        case .sharedFolder:
            "Script is delivered via a shared folder and run by a watcher."
        }
    }

    /// A detailed explanation of when and why to use this mode.
    /// Used in the GUI, CLI help, and documentation.
    public var explanation: String {
        switch self {
        case .diskInject:
            """
            Your script runs automatically when macOS starts — no SSH, \
            no agent, no network, and no manual setup required. \
            Before the VM boots, Spooktacular writes a standard macOS \
            LaunchDaemon to the guest's disk that executes your script \
            at startup.

            Best for: Fresh VMs from IPSW, CI runners, zero-touch \
            fleet provisioning. This is the only mode that works on \
            a completely vanilla macOS with no prior configuration.
            """

        case .ssh:
            """
            Spooktacular waits for the VM to boot, discovers its IP \
            address, connects via SSH, and runs your script. You get \
            real-time output streaming and full control.

            Best for: Cloned VMs where the base image has Remote Login \
            (SSH) enabled. Development and debugging workflows where \
            you want to watch output as it runs.

            Requires: Remote Login enabled in the guest (System \
            Settings → General → Sharing → Remote Login).
            """

        case .agent:
            """
            The Spooktacular guest agent communicates with the host \
            over a VirtIO socket — a direct channel that works without \
            any network configuration. The host sends your script to \
            the agent, which executes it and streams output back.

            Best for: VMs created from Spooktacular's official OCI \
            images (ghcr.io/spooktacular/), which include the agent. \
            This is the fastest mode and works with isolated \
            (no-network) VMs.

            Requires: The guest agent installed in the VM (pre-installed \
            in Spooktacular OCI images).
            """

        case .sharedFolder:
            """
            Spooktacular shares a host directory into the VM using \
            VirtIO. A watcher daemon in the guest detects new scripts \
            in the shared folder and executes them automatically.

            Best for: Cloned VMs where SSH is not available and you \
            prefer not to modify the guest disk. The base image needs \
            a one-time setup of the watcher daemon.

            Requires: The shared-folder watcher installed in the base \
            image (included in Spooktacular OCI images, or install \
            with 'spook tools install <vm-name>').
            """
        }
    }
}
