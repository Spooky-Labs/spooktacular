import Foundation

/// A single Help topic rendered in the in-app Help window.
///
/// Topics are static Swift values stored in ``HelpTopicLibrary`` —
/// no I/O, no bundle lookup, no localization loader. They render
/// via `AttributedString(markdown:)` in ``HelpView``.
///
/// Authoring a new topic is just appending a new `HelpTopic` to
/// the ``HelpTopicLibrary/topics`` array. The slug must be stable
/// and URL-safe because it's the identifier we pass through
/// `openWindow(id: "help", value: slug)` from the Help menu.
///
/// Docs (AttributedString Markdown): https://developer.apple.com/documentation/foundation/attributedstring/init(markdown:)
struct HelpTopic: Identifiable, Hashable {

    /// URL-safe stable identifier. Passed via `openWindow(id:
    /// "help", value: slug)` when a Help menu item should
    /// pre-select this topic.
    let slug: String

    /// Category this topic belongs to — drives the sidebar
    /// section grouping. Must match one of the
    /// ``HelpCategory/id`` values in ``HelpTopicLibrary``.
    let category: String

    /// Sidebar label + page headline.
    let title: String

    /// One-line subtitle beneath the page headline.
    let subtitle: String

    /// SF Symbol name used for the sidebar row and the page
    /// header. Pick an existing symbol — the Help window does not
    /// render a fallback glyph.
    let systemImage: String

    /// Markdown body rendered by ``HelpView``. Supports headings,
    /// paragraphs, lists, inline code, bold/italic, and links.
    let body: String

    var id: String { slug }
}

/// A category header in the Help sidebar. Categories only supply
/// a title and a stable id — topics themselves reference the id
/// via ``HelpTopic/category``.
struct HelpCategory: Identifiable, Hashable {

    /// Stable id referenced by ``HelpTopic/category``.
    let id: String

    /// Sidebar section header label.
    let title: String
}

/// Static registry of Help categories and topics. The categories
/// appear in the sidebar in the order declared here; within each
/// category the topics render in `topics` array order.
///
/// Why a static array instead of a bundle-loaded plist?
/// - Compile-time string checking (no locale-loader typos).
/// - Zero I/O at window open — topics render instantly.
/// - Adds-a-topic diff is one Swift literal, no tooling.
///
/// Docs: https://developer.apple.com/documentation/swiftui/navigationsplitview
enum HelpTopicLibrary {

    /// The category list shown in the Help sidebar, in display
    /// order.
    static let categories: [HelpCategory] = [
        HelpCategory(id: "getting-started", title: "Getting Started"),
        HelpCategory(id: "ci-runners", title: "CI/CD Runners"),
        HelpCategory(id: "remote-desktop", title: "Remote Desktop"),
        HelpCategory(id: "agents", title: "AI Agents"),
        HelpCategory(id: "security", title: "Security"),
        HelpCategory(id: "cli", title: "CLI Reference"),
        HelpCategory(id: "troubleshooting", title: "Troubleshooting"),
    ]

    /// All Help topics, grouped by ``HelpTopic/category``. Sidebar
    /// render order matches this declaration order.
    static let topics: [HelpTopic] = [
        // MARK: Getting Started
        HelpTopic(
            slug: "welcome",
            category: "getting-started",
            title: "Welcome to Spooktacular",
            subtitle: "Run macOS workspaces on your Mac — fast.",
            systemImage: "sparkles",
            body: """
                Spooktacular is a macOS-native virtualization app. \
                Every workspace is a real macOS install running on \
                Apple's Virtualization.framework — with a Metal-backed \
                GPU, VirtIO audio and shared folders, and a custom \
                guest agent for high-signal telemetry.

                **Your first workspace**
                - Click **Create Workspace** in the sidebar toolbar.
                - Pick **Latest compatible** to fetch the newest macOS \
                  IPSW from Apple (≈12 GB), or **Local IPSW file** if \
                  you already have one on disk.
                - Choose CPU / RAM / disk — defaults are sensible for \
                  a developer workspace.
                - Click **Create**. The library window stays \
                  responsive while macOS installs.

                **After first boot**
                - Double-click the workspace in the sidebar to open \
                  it in its own window.
                - Toolbar **Stop**, **Snapshots**, **Ports**, and \
                  **Copy IP** give you the live VM controls without \
                  dropping to Terminal.

                Spooktacular ships a `spook` CLI alongside the GUI — \
                everything the GUI can do, the CLI can do headlessly. \
                See the **CLI Reference** section for the full \
                command surface.
                """
        ),
        HelpTopic(
            slug: "creating-a-vm",
            category: "getting-started",
            title: "Creating a Virtual Machine",
            subtitle: "CPU, memory, disk, network, shared folders.",
            systemImage: "plus.square.on.square",
            body: """
                The **New Virtual Machine** sheet is the full \
                configuration surface for a workspace. Each control \
                has an inline explanation on the right; the short \
                form is below.

                **Name** — Unique across your library. Used as the \
                CLI identifier (`spook start <name>`) and the \
                window title.

                **macOS Source** — "Latest compatible" downloads from \
                Apple; "Local IPSW file" skips the download. The IPSW \
                cache lives under `~/.spooktacular/ipsw/`, \
                deduplicated by SHA-256 so the second VM skips the \
                download.

                **Hardware** — macOS VMs need ≥4 cores. Memory comes \
                from your Mac's unified RAM. The disk is APFS sparse, \
                so a 64 GB disk only consumes host space the guest \
                actually writes.

                **Network** — *NAT* routes via your Mac's connection. \
                *Bridged* gives the VM its own LAN IP (requires the \
                `com.apple.vm.networking` entitlement). *Isolated* \
                has no network interface — host-guest communication \
                is still possible over VirtIO sockets.

                **Shared Folders** — Host directories mounted into \
                the guest at `/Volumes/My Shared Files/`. Useful for \
                source trees, artifacts, and read-only keys.

                **Provisioning** — Pick a first-boot template \
                (GitHub Actions Runner, OpenClaw agent, Remote \
                Desktop) or supply a custom shell script.
                """
        ),
        HelpTopic(
            slug: "keyboard-shortcuts",
            category: "getting-started",
            title: "Keyboard Shortcuts",
            subtitle: "Jump straight to the action you need.",
            systemImage: "keyboard",
            body: """
                **Library window**
                - ⌘N — New Virtual Machine
                - ⇧⌘I — Add Image
                - ⌘K — Command Palette
                - ⌘? — Open this Help window

                **Workspace window**
                - ⇧⌘S — Snapshots
                - ⇧⌘H — Hardware Editor
                - ⇧⌘P — Listening Ports
                - ⌘W — Close workspace (VM keeps running unless you \
                  Stop it)

                **Command Palette (⌘K)**
                - Fuzzy-matches both action names and VM names.
                - Enter runs the top match.
                - Esc dismisses.
                """
        ),

        // MARK: CI/CD Runners
        HelpTopic(
            slug: "github-runner",
            category: "ci-runners",
            title: "GitHub Actions Runner",
            subtitle: "Turn a workspace into a self-hosted runner.",
            systemImage: "hammer.circle",
            body: """
                Spooktacular runs GitHub Actions jobs inside a \
                macOS workspace with no external runner host. The \
                **GitHub Actions Runner** provisioning template \
                configures a fresh runner on first boot and \
                registers it with your repo.

                **Setup**
                1. Add the runner registration token to the \
                   Keychain:
                   ```
                   security add-generic-password \\
                     -s com.spooktacular.github \\
                     -a <account> \\
                     -w <token> -U
                   ```
                2. In **Create Virtual Machine**, pick the \
                   "GitHub Actions Runner" template.
                3. Set **owner/repo** (e.g. `acme-inc/platform`) \
                   and the **Keychain account** from step 1.
                4. (Optional) Enable **Ephemeral** — the runner \
                   exits after one job.

                **Ephemeral runners**
                Pair the ephemeral flag with `spook snapshot \
                restore` before each run to get a pristine \
                environment per job. The agent's state machine \
                reclones the VM automatically when one exits.

                **Security**
                Spooktacular reads the registration token only \
                from the Keychain. Env-var / CLI-flag / file \
                paths were removed pre-1.0 so the token never \
                lands in `ps`, `launchctl print`, or \
                plaintext-on-disk.
                """
        ),
        HelpTopic(
            slug: "runner-pools",
            category: "ci-runners",
            title: "Runner Pools",
            subtitle: "Clone one workspace into a fleet of runners.",
            systemImage: "square.stack.3d.up",
            body: """
                Clone your provisioned runner workspace into a \
                pool using APFS copy-on-write. Each clone shares \
                disk blocks with the source until it writes, so a \
                100 GB disk clones in milliseconds.

                **CLI**
                ```
                spook clone runner-base runner-01
                spook clone runner-base runner-02
                spook clone runner-base runner-03
                ```

                **GUI**
                - Right-click a workspace in the sidebar → **Clone…**
                - Pick a destination name (default: `<source>-clone`)
                - Click **Clone**

                Each clone gets a freshly regenerated machine \
                identifier so both VMs can run concurrently \
                without Virtualization.framework collisions.
                """
        ),

        // MARK: Remote Desktop
        HelpTopic(
            slug: "remote-desktop-intro",
            category: "remote-desktop",
            title: "Remote Desktop",
            subtitle: "VNC access to a workspace from any device.",
            systemImage: "display",
            body: """
                The **Remote Desktop (VNC)** provisioning template \
                enables macOS Screen Sharing on first boot so you \
                can connect to the workspace from another Mac, \
                iPad, or PC.

                **Setup**
                1. In **Create Virtual Machine**, pick the \
                   "Remote Desktop (VNC)" template.
                2. After first boot, look at the workspace's \
                   system log for the VNC URL. Or just run \
                   `spook ip <vm>` to get the IP.
                3. Connect with any VNC client: \
                   `vnc://admin@<ip>`.

                **Tips**
                - Enable **Auto-resize display** in Create so the \
                  guest resolution tracks your VNC client's \
                  window.
                - Use **Bridged** networking if you want the VM \
                  reachable at a stable LAN IP.
                """
        ),

        // MARK: AI Agents
        HelpTopic(
            slug: "openclaw-agent",
            category: "agents",
            title: "OpenClaw Agent",
            subtitle: "Sandbox a Node.js gateway inside a workspace.",
            systemImage: "brain",
            body: """
                The **OpenClaw AI Agent** provisioning template \
                installs Node.js plus the OpenClaw gateway daemon \
                on first boot so the workspace acts as a sandboxed \
                agent host.

                **Secrets handling**
                Pass API keys via a **Shared Folder** rather than \
                baking them into the provisioning script — the \
                guest mounts the folder at `/Volumes/My Shared \
                Files/<tag>` and the daemon reads from there on \
                startup. This keeps secrets out of the \
                provisioning script, out of the VM's disk image \
                if it's ever cloned, and off the \
                provisioning-script's audit trail.
                """
        ),

        // MARK: Security
        HelpTopic(
            slug: "data-at-rest",
            category: "security",
            title: "Data at Rest",
            subtitle: "Bundle protection and the 'stolen laptop' threat.",
            systemImage: "lock.shield",
            body: """
                Spooktacular protects workspace bundles on disk \
                via the **Bundle Protection Policy** under \
                **Settings → Security**. Three choices:

                - **Automatic (recommended)** — Detects whether \
                  this Mac is a laptop (battery present) and \
                  applies CUFUA on laptops, off on desktops and \
                  EC2 Mac hosts.
                - **Protected (CUFUA)** — Bundles are encrypted \
                  with the **CompleteUntilFirstUserAuth** file \
                  protection class. They're unreadable until you \
                  unlock the Mac once after reboot.
                - **Off** — Bundles are readable by any process \
                  running as you, including pre-login daemons.

                **Why CUFUA?** It defeats the "stolen laptop with \
                a compromised FileVault recovery key" attack — the \
                attacker can mount your drive but can't read \
                workspace bundles until they unlock the machine \
                again, which they can't.

                **Existing bundles** stay unprotected after you \
                change the setting. Run `spook bundle protect \
                --all` to bring them up to policy.
                """
        ),
        HelpTopic(
            slug: "keychain-secrets",
            category: "security",
            title: "Keychain and Secrets",
            subtitle: "Where Spooktacular stores tokens, keys, and TLS material.",
            systemImage: "key.fill",
            body: """
                Spooktacular never accepts a secret via \
                environment variable, CLI flag, or plaintext file \
                path. All tokens, keys, and TLS material are read \
                from the macOS Keychain by service name.

                **Service names**
                - `com.spooktacular.github` — GitHub Actions \
                  runner registration tokens
                - `com.spooktacular.tls` — mTLS client/server \
                  certificates
                - `com.spooktacular.agent` — guest-agent auth \
                  tokens

                **Adding a token**
                ```
                security add-generic-password \\
                  -s <service> \\
                  -a <account> \\
                  -w <secret> -U
                ```

                **Why not env vars?** Anything in the process \
                environment shows up in `ps -e`, `launchctl \
                print`, and crash reports. Keychain items don't.
                """
        ),

        // MARK: CLI Reference
        HelpTopic(
            slug: "cli-basics",
            category: "cli",
            title: "CLI Basics",
            subtitle: "The `spook` command line.",
            systemImage: "terminal",
            body: """
                The `spook` CLI ships inside the app bundle and \
                mirrors every GUI action. Add it to your `$PATH`:

                ```
                sudo ln -s /Applications/Spooktacular.app/Contents/MacOS/spook \\
                  /usr/local/bin/spook
                ```

                **Common commands**
                - `spook list` — list all workspaces + status
                - `spook create <name>` — create a new workspace
                - `spook start <name>` — boot a workspace
                - `spook stop <name>` — stop a workspace
                - `spook ip <name>` — resolve the workspace's \
                  IPv4 address
                - `spook ssh <name>` — SSH as `admin`
                - `spook clone <source> <dest>` — APFS clone
                - `spook snapshot save <name> <label>` — snapshot \
                  the disk
                - `spook snapshot restore <name> <label>` — revert
                - `spook delete <name>` — remove a workspace

                Run `spook help <subcommand>` for per-command \
                docs.
                """
        ),
        HelpTopic(
            slug: "cli-scripting",
            category: "cli",
            title: "Scripting with spook",
            subtitle: "Integrate workspaces into build and deploy scripts.",
            systemImage: "scroll",
            body: """
                Every `spook` subcommand emits machine-readable \
                output when run non-interactively. Use \
                `--output json` to get structured data you can \
                pipe through `jq`:

                ```
                spook list --output json | jq '.[] | \
                  select(.running) | .name'
                ```

                Exit codes follow the standard `sysexits.h` \
                convention — 0 on success, 64+ for usage errors, \
                74 for I/O errors. Scripts that want to treat \
                "VM doesn't exist" as a soft condition should \
                check for exit code 66 (`EX_NOINPUT`).
                """
        ),

        // MARK: Troubleshooting
        HelpTopic(
            slug: "vm-wont-start",
            category: "troubleshooting",
            title: "A VM won't start",
            subtitle: "What to check when Start fails silently or with an error.",
            systemImage: "exclamationmark.triangle",
            body: """
                **1. Check the error message.** The Create / Start \
                flow classifies errors into three tiers: a short \
                headline, a recovery suggestion, and (sometimes) a \
                copy-pasteable `security` or `spook` fix.

                **2. Check the log.** Run:
                ```
                log show --predicate 'subsystem == \
                  "ai.spookylabs.spooktacular"' --info --last 10m
                ```

                **3. Common causes**
                - *Bundle protection locked:* you haven't unlocked \
                  the Mac after reboot. Log in first, then retry.
                - *IPSW missing:* the local IPSW path you supplied \
                  doesn't exist. Re-browse with the sheet's \
                  **Browse…** button.
                - *Machine identifier collision:* another copy of \
                  the VM is already booting. Check \
                  `spook list --output json` for double-counts.
                """
        ),
        HelpTopic(
            slug: "networking-issues",
            category: "troubleshooting",
            title: "Networking issues",
            subtitle: "When the guest can't reach the network or the host can't see the guest.",
            systemImage: "network.badge.shield.half.filled",
            body: """
                **Guest has no IP** — The DHCP handshake with the \
                host's vmnet service can take ≈15 s at cold boot. \
                If it's still missing after 30 s, check:

                - Is the workspace set to **Isolated**? That mode \
                  has no network interface.
                - Is the host Mac's firewall blocking vmnet? \
                  **System Settings → Network → Firewall** →\
                  unblock Virtualization.framework processes.

                **Host can't reach the guest's IP** — Spooktacular \
                resolves the IP from the host's DHCP lease table \
                plus ARP. If the lease is stale, re-resolve via \
                **Copy IP** in the workspace toolbar; it \
                re-queries the current lease.

                **Bridged mode fails silently** — Bridged \
                networking requires the \
                `com.apple.vm.networking` entitlement. The signed \
                App Store build carries it; local unsigned dev \
                builds don't.
                """
        ),
    ]

    /// Look up a topic by its slug. Returns nil for unknown
    /// slugs — callers (the `HelpView` detail pane) fall back to
    /// an empty state.
    static func topic(forSlug slug: String) -> HelpTopic? {
        topics.first { $0.slug == slug }
    }
}
