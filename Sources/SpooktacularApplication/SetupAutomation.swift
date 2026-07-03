import Foundation
import SpooktacularCore

// MARK: - Errors

/// An error that occurs when a Setup Assistant automation
/// sequence is requested for an unsupported environment.
///
/// Returning a ``BootStep`` array of zero length would masquerade
/// as success — the executor would run zero steps and the caller
/// would see a "fresh" VM stuck on the language picker. Throwing
/// forces the caller to decide: fall back to interactive setup,
/// fail loudly, or map to a different macOS automation sequence.
public enum SetupAutomationError: Error, Sendable, Equatable, LocalizedError {

    /// No automation sequence is registered for the requested macOS
    /// major version.
    ///
    /// - Parameters:
    ///   - requested: The macOS major version number the caller
    ///     asked for.
    ///   - supported: The versions that have a registered sequence
    ///     at the time of the call.
    case unsupportedVersion(requested: Int, supported: Set<Int>)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let requested, let supported):
            let list = supported.sorted().map(String.init).joined(separator: ", ")
            return "No Setup Assistant automation sequence for macOS \(requested). "
                + "Supported versions: \(list)."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unsupportedVersion:
            "Install a supported macOS version from an IPSW, or skip Setup "
            + "Assistant automation and complete setup interactively with "
            + "`spook start <name>`."
        }
    }
}

// MARK: - Boot Step Types

/// A single step in a Setup Assistant automation sequence.
///
/// Each `BootStep` pairs a delay (time to wait before acting) with
/// an action to perform. The delay accounts for Setup Assistant
/// screen transitions, which vary depending on the macOS version
/// and VM performance.
///
/// ## How It Works
///
/// Setup Assistant automation sends keyboard input to the VM's
/// virtual display using `VZVirtualMachineView`. This follows the
/// same approach used by [Tart](https://github.com/cirruslabs/tart)
/// for Packer `boot_command` sequences, which has been proven
/// reliable across macOS 13 through 26.
///
/// > Important: A `VZVirtualMachineView` must be attached to the
/// > VM (even offscreen) for keyboard events to be delivered.
/// > Without a view, the Virtualization framework discards
/// > keyboard input.
///
/// ## Example
///
/// ```swift
/// let step = BootStep(delay: 10, action: .text("admin"))
/// ```
public struct BootStep: Sendable, Equatable {

    /// Time in seconds to wait before performing the action.
    ///
    /// This delay accounts for Setup Assistant screen transitions.
    /// Longer delays are used after steps that trigger animations
    /// or network activity (e.g., account creation).
    public let delay: TimeInterval

    /// The keyboard action to perform after the delay elapses.
    public let action: BootAction

    /// Creates a boot step with a delay and action.
    ///
    /// - Parameters:
    ///   - delay: Seconds to wait before performing the action.
    ///   - action: The keyboard action to perform.
    public init(delay: TimeInterval, action: BootAction) {
        self.delay = delay
        self.action = action
    }
}

/// A keyboard action to send to the VM during Setup Assistant automation.
///
/// Actions map to keyboard events delivered through
/// `VZVirtualMachineView`. Text actions generate a sequence of
/// key-down/key-up pairs for each character. Key and shortcut
/// actions generate a single key event with optional modifiers.
///
/// ## Example
///
/// ```swift
/// let typeAction = BootAction.text("admin")
/// let enterAction = BootAction.key(.returnKey)
/// let spotlightAction = BootAction.shortcut(.space, modifiers: [.option])
/// ```
public enum BootAction: Sendable, Equatable {

    /// Type a string of characters, one key event per character.
    case text(String)

    /// Press and release a single key.
    case key(KeyCode)

    /// Press a key with one or more modifier keys held down.
    case shortcut(KeyCode, modifiers: [Modifier])

    /// Wait for an additional duration without sending any input.
    ///
    /// Use this for long pauses within a step sequence, such as
    /// waiting for account creation to complete.
    case wait(TimeInterval)

    /// Wait until specific text appears on the VM screen before proceeding.
    ///
    /// When a ``ScreenReader`` is available, this action polls the
    /// screen using OCR until the specified text is found. If no
    /// screen reader is provided, falls back to a fixed delay equal
    /// to the timeout duration.
    ///
    /// - Parameters:
    ///   - text: The text to wait for (case-insensitive substring match).
    ///   - timeout: Maximum seconds to wait. Defaults to 120.
    case waitForText(String, timeout: TimeInterval = 120)

    /// Click on text visible on the VM screen.
    ///
    /// When a ``ScreenReader`` is available, this action waits for
    /// the specified text to appear, computes the center of its
    /// bounding box, and sends a mouse click at that location using
    /// the ``KeyboardDriver/clickAt(x:y:)`` method. If no screen
    /// reader is provided, the action is skipped with a warning.
    ///
    /// - Parameters:
    ///   - text: The text to find and click (case-insensitive).
    ///   - timeout: Maximum seconds to wait for the text. Defaults to 60.
    case clickText(String, timeout: TimeInterval = 60)

    /// Block until the VM screen shows one of several candidate
    /// marker strings, confirming a Setup Assistant screen
    /// transition actually happened before any further keystroke is
    /// sent.
    ///
    /// This is the gate primitive that replaces blind fixed-delay
    /// waits at screen transitions (see ``SetupAutomation``'s
    /// `sequoiaSequence` segment functions). Where ``waitForText(_:timeout:)``
    /// matches a single string, `expectScreen` accepts several
    /// candidates joined by OR — useful both because a screen may be
    /// identifiable by more than one stable phrase, and as a hedge
    /// against uncertainty about the *exact* wording of Setup
    /// Assistant copy (which Apple does not publish as a documented
    /// API surface, and which this project has not been able to
    /// verify empirically against a live VM at authoring time — see
    /// the per-call-site comments in `sequoiaSequence` for the
    /// reasoning behind each marker choice).
    ///
    /// When a ``ScreenReader`` is available, the executor polls the
    /// screen (bounded cadence, ~2s by default) until any marker is
    /// found as a case-insensitive substring of some recognized text
    /// region, or `timeout` elapses. On timeout the executor saves a
    /// screenshot (when the reader also conforms to
    /// ``SpooktacularCore/ScreenshotCapturing``) and the full OCR
    /// dump to disk, then throws a diagnostic error naming the step,
    /// the expected markers, and an excerpt of what was actually on
    /// screen. Without a screen reader, this action falls back to a
    /// fixed delay of `timeout` seconds and never fails — matching
    /// ``waitForText(_:timeout:)``'s no-reader fallback.
    ///
    /// - Parameters:
    ///   - markers: Candidate substrings — any one appearing on
    ///     screen satisfies the gate. Case-insensitive.
    ///   - timeout: Maximum seconds to wait before failing with a
    ///     diagnostic error.
    case expectScreen(containsAny: [String], timeout: TimeInterval)
}

// KeyCode and Modifier are defined in SpooktacularCore/KeyCode.swift

// MARK: - Setup Automation

/// Automated macOS Setup Assistant sequences for headless VM provisioning.
///
/// `SetupAutomation` provides version-specific keyboard input sequences
/// that walk through the macOS Setup Assistant without any human
/// interaction. After the sequence completes, the VM has:
///
/// - A user account (configurable, defaults to `admin`/`admin`)
/// - SSH (Remote Login) enabled
/// - A UTC timezone configured
///
/// ## Design
///
/// This follows the approach pioneered by
/// [Tart](https://github.com/cirruslabs/tart) for Packer
/// `boot_command` automation. The sequences have been verified against
/// Tart's working Packer plugin and adapted for direct use via the
/// Virtualization framework's keyboard API.
///
/// ## Requirements
///
/// - A `VZVirtualMachineView` must be attached to the VM (even
///   offscreen) for keyboard events to reach the guest.
/// - The VM must be freshly installed from an IPSW --- previously
///   configured VMs will not show the Setup Assistant.
/// - Sequences are version-specific because Apple changes the Setup
///   Assistant layout between major macOS releases.
///
/// ## Example
///
/// ```swift
/// guard SetupAutomation.isSupported(macOSVersion: 15) else {
///     fatalError("No automation sequence for this version")
/// }
///
/// let steps = SetupAutomation.sequence(for: 15)
/// for step in steps {
///     try await Task.sleep(for: .seconds(step.delay))
///     await keyboardDriver.perform(step.action)
/// }
/// ```
///
/// ## Adding Support for New macOS Versions
///
/// When a new macOS version ships, its Setup Assistant layout must
/// be mapped by hand:
///
/// 1. Install the new macOS in a VM with a display attached.
/// 2. Walk through Setup Assistant, recording each screen's
///    navigation keys.
/// 3. Add a new `case` in ``sequence(for:username:password:)``
///    with the recorded steps.
/// 4. Test against a fresh IPSW install.
public enum SetupAutomation {

    /// The macOS major versions that have automation sequences.
    ///
    /// Currently supported: macOS 15 (Sequoia) and macOS 26 (Tahoe).
    public static let supportedVersions: Set<Int> = [15, 26]

    /// Whether a boot automation sequence exists for the given macOS major version.
    ///
    /// - Parameter macOSVersion: The major version number (e.g., 15 for Sequoia).
    /// - Returns: `true` if ``sequence(for:username:password:)`` will return
    ///   a non-empty sequence for this version.
    public static func isSupported(macOSVersion: Int) -> Bool {
        supportedVersions.contains(macOSVersion)
    }

    /// Returns the boot automation sequence for a given macOS major version.
    ///
    /// The returned steps, when executed in order, navigate through every
    /// screen of the macOS Setup Assistant and finish by enabling SSH
    /// via Terminal.
    ///
    /// Each step's ``BootStep/delay`` should be awaited before performing
    /// the ``BootStep/action``. The delays are conservative to account
    /// for slower VMs --- on fast hardware, some screens may transition
    /// sooner.
    ///
    /// - Parameters:
    ///   - macOSVersion: The major version number (e.g., 15 for Sequoia,
    ///     26 for Tahoe).
    ///   - username: The account name and full name for the admin user.
    ///     Defaults to `"admin"`.
    ///   - password: The password for the admin user. Defaults to
    ///     `"admin"`.
    ///
    ///     > Important: This value is typed verbatim into a live
    ///     > Terminal shell prompt — once during account creation
    ///     > and again after every `sudo` in
    ///     > ``enableSSHSteps(password:)`` /
    ///     > ``installProvisionerSteps(password:)`` (the
    ///     > retype-after-sudo pattern). None of those call sites
    ///     > shell-escape it, so it must not contain shell
    ///     > metacharacters (`'`, `"`, `` ` ``, `$`, `\`, newlines)
    ///     > — every call site today passes the hardcoded default
    ///     > `"admin"`, so this is latent, not exploitable, but a
    ///     > future caller supplying an operator-chosen password
    ///     > must sanitize it first.
    ///   - installProvisioner: When `true`, appends
    ///     ``installProvisionerSteps(password:)`` to the end of the
    ///     sequence so it runs inside the same Terminal session
    ///     opened for SSH enablement. Defaults to `false`, which
    ///     produces a sequence byte-identical to calling this
    ///     method without the parameter at all. Callers should only
    ///     pass `true` after confirming `Spooktacular Provisioner.pkg`
    ///     was actually staged into the VM's provisioning share
    ///     (see ``AppBundleBootstrapTemplate/locateProvisionerPkg()``)
    ///     — typing the `installer` command against a pkg that was
    ///     never copied in just fails loudly inside the guest for
    ///     no benefit.
    /// - Returns: An ordered, non-empty array of boot steps.
    /// - Throws: ``SetupAutomationError/unsupportedVersion(requested:supported:)``
    ///   when no registered sequence matches the macOS version. Callers
    ///   receive an actionable error instead of a silently-empty step
    ///   list that would leave the VM stranded on the first Setup
    ///   Assistant screen.
    public static func sequence(
        for macOSVersion: Int,
        username: String = "admin",
        password: String = "admin",
        installProvisioner: Bool = false
    ) throws -> [BootStep] {
        switch macOSVersion {
        case 15, 26:
            return sequoiaSequence(
                username: username,
                password: password,
                installProvisioner: installProvisioner
            )
        default:
            throw SetupAutomationError.unsupportedVersion(
                requested: macOSVersion,
                supported: supportedVersions
            )
        }
    }

    // MARK: - macOS 15 (Sequoia)

    /// The Setup Assistant automation sequence for macOS 15 (Sequoia).
    ///
    /// Verified against Tart's Packer boot_command for macOS 15.
    /// The sequence navigates: Language -> Country -> Transfer Data ->
    /// Languages -> Accessibility -> Data & Privacy -> Account Creation ->
    /// Apple ID -> Terms -> Location -> Timezone -> Analytics ->
    /// Screen Time -> Siri -> Choose Look -> Auto Update -> Welcome,
    /// then enables SSH via Terminal.
    private static func sequoiaSequence(
        username: String,
        password: String,
        installProvisioner: Bool
    ) -> [BootStep] {
        let steps = languageAndCountrySteps()
            + transferDataSteps()
            + skipScreenSteps()
            + accountCreationSteps(username: username, password: password)
            + postAccountSteps()
            + timezoneSteps()
            + finalScreensSteps()
            + enableSSHSteps(password: password)
        guard installProvisioner else { return steps }
        // Appended, not woven in: `enableSSHSteps` never closes
        // Terminal, so the session it opened is still the
        // foreground app and still has a live shell prompt when
        // these steps begin.
        return steps + installProvisionerSteps(username: username, password: password)
    }

    // MARK: - Sequoia Sequence Segments

    private static let shiftTab = BootAction.shortcut(.tab, modifiers: [.shift])
    private static let tab = BootAction.key(.tab)
    private static let space = BootAction.key(.space)
    private static let enter = BootAction.key(.returnKey)
    private static let voiceover = BootAction.shortcut(.f5, modifiers: [.option])

    /// Wait for boot, dismiss Hello, select language and country.
    ///
    /// The very first `wait(0)` step keeps its blind 60s delay
    /// rather than becoming a screen gate: the screen it's waiting
    /// on (the multi-language "Hello" welcome animation) cycles
    /// through greeting text in dozens of languages with no single
    /// substring guaranteed present at any given poll, and no
    /// language has been selected yet to make an English marker
    /// safe. Every gate from here on can rely on English text
    /// because ``sequoiaSequence`` sets the language to English
    /// before any later screen renders.
    private static func languageAndCountrySteps() -> [BootStep] {
        [
            BootStep(delay: 60, action: .wait(0)),
            BootStep(delay: 0, action: space),
            // "English" is the language's own autonym — spelled
            // "English" in every locale's language-name list, not
            // translated — so it's a safe marker even though the
            // system's default language is still unknown at this
            // point in the flow.
            BootStep(delay: 0, action: .expectScreen(containsAny: ["English"], timeout: 120)),
            BootStep(delay: 0, action: .text("italiano")),
            BootStep(delay: 0, action: .key(.escape)),
            BootStep(delay: 0, action: .text("english")),
            BootStep(delay: 0, action: enter),
            BootStep(delay: 0, action: .expectScreen(
                containsAny: ["Select Your Country", "Country or Region"],
                timeout: 60
            )),
            BootStep(delay: 0, action: .text("united states")),
            BootStep(delay: 0, action: shiftTab),
            BootStep(delay: 0, action: space),
        ]
    }

    /// Skip Transfer Data (Not Now).
    private static func transferDataSteps() -> [BootStep] {
        [
            BootStep(delay: 0, action: .expectScreen(
                containsAny: ["Migration Assistant", "Transfer Your Data"],
                timeout: 60
            )),
            BootStep(delay: 0, action: tab),
            BootStep(delay: 0, action: tab),
            BootStep(delay: 0, action: tab),
            BootStep(delay: 0, action: space),
            BootStep(delay: 0, action: tab),
            BootStep(delay: 0, action: tab),
            BootStep(delay: 0, action: space),
        ]
    }

    /// Skip Additional Languages, Accessibility, Data & Privacy.
    ///
    /// Left as blind per-screen delays rather than gated: this
    /// project has no verified marker text for these three specific
    /// screens (their consolidated titles have shifted across recent
    /// macOS Setup Assistant redesigns), and Apple does not document
    /// OOBE screen copy as an API surface to check against. Guessing
    /// a marker here risks a *false-negative* gate — one that never
    /// matches and turns a working blind wait into a hard failure —
    /// which is worse than the status quo. The eight transitions
    /// gated elsewhere in this sequence (language, country,
    /// migration, account creation, Apple ID, terms, location, time
    /// zone) plus the Terminal/SSH and provisioner-install gates were
    /// chosen because their marker text is well established.
    private static func skipScreenSteps() -> [BootStep] {
        // Each screen: Shift-Tab to focus Continue, Space to press.
        (0..<3).flatMap { _ -> [BootStep] in
            [BootStep(delay: 10, action: shiftTab), BootStep(delay: 0, action: space)]
        }
    }

    /// Fill account creation form.
    ///
    /// The trailing `voiceover` toggle's old `delay: 120` blind wait
    /// covered account creation actually being processed (it can be
    /// noticeably slower than a plain screen transition) before the
    /// Apple ID screen appears. That role now belongs to the
    /// `expectScreen` gate immediately before it — generously bounded
    /// at 120s, same tier as first-boot — so the voiceover action
    /// itself carries no additional delay.
    private static func accountCreationSteps(
        username: String,
        password: String
    ) -> [BootStep] {
        [
            BootStep(delay: 0, action: .expectScreen(
                containsAny: ["Create a Computer Account", "Account Name"],
                timeout: 60
            )),
            BootStep(delay: 0, action: .text(username)),
            BootStep(delay: 0, action: tab),
            BootStep(delay: 0, action: .text(username)),
            BootStep(delay: 0, action: tab),
            BootStep(delay: 0, action: .text(password)),
            BootStep(delay: 0, action: tab),
            BootStep(delay: 0, action: .text(password)),
            BootStep(delay: 0, action: tab),
            BootStep(delay: 0, action: tab),
            BootStep(delay: 0, action: space),
            BootStep(delay: 0, action: tab),
            BootStep(delay: 0, action: tab),
            BootStep(delay: 0, action: space),
            BootStep(delay: 0, action: .expectScreen(
                containsAny: ["Sign In with Your Apple ID", "Apple ID"],
                timeout: 120
            )),
            BootStep(delay: 0, action: voiceover),
        ]
    }

    /// Apple ID, Terms, Location screens.
    ///
    /// The leading Apple ID step no longer carries its own delay:
    /// ``accountCreationSteps(username:password:)`` already gated on
    /// the Apple ID screen being visible immediately before this
    /// function runs. The `delay: 10` steps that remain are
    /// within-screen — waiting for a confirmation popover ("Skip" /
    /// "Agree" confirm dialogs) layered on the *same* screen, not a
    /// full transition — so they stay as small fixed delays per the
    /// gate design (gates replace transition waits, not every pause).
    private static func postAccountSteps() -> [BootStep] {
        [
            BootStep(delay: 0, action: shiftTab),  // Skip Apple ID
            BootStep(delay: 0, action: space),
            BootStep(delay: 10, action: tab),        // Confirm Skip
            BootStep(delay: 0, action: space),
            BootStep(delay: 0, action: .expectScreen(
                containsAny: ["Terms and Conditions", "Terms of Use"],
                timeout: 60
            )),
            BootStep(delay: 0, action: shiftTab),  // Terms (Agree)
            BootStep(delay: 0, action: space),
            BootStep(delay: 10, action: tab),        // Confirm Terms
            BootStep(delay: 0, action: space),
            BootStep(delay: 0, action: .expectScreen(
                containsAny: ["Enable Location Services", "Location Services"],
                timeout: 60
            )),
            BootStep(delay: 0, action: shiftTab),  // Skip Location
            BootStep(delay: 0, action: space),
            BootStep(delay: 10, action: tab),        // Confirm Skip
            BootStep(delay: 0, action: space),
        ]
    }

    /// Set timezone to UTC.
    private static func timezoneSteps() -> [BootStep] {
        [
            BootStep(delay: 0, action: .expectScreen(
                containsAny: ["Select Your Time Zone", "Time Zone"],
                timeout: 60
            )),
            BootStep(delay: 0, action: tab),
            BootStep(delay: 0, action: tab),
            BootStep(delay: 0, action: .text("UTC")),
            BootStep(delay: 0, action: enter),
            BootStep(delay: 0, action: shiftTab),
            BootStep(delay: 0, action: shiftTab),
            BootStep(delay: 0, action: space),
        ]
    }

    /// Analytics, Screen Time, Siri, Choose Look, Auto Update, Welcome.
    ///
    /// Same rationale as ``skipScreenSteps()``: no verified marker
    /// text for these six screens, so they stay blind delays rather
    /// than risk a false-negative gate. The next gate after this
    /// function's steps run is `expectScreen(containsAny: ["Spotlight
    /// Search", "Spotlight"])` in ``enableSSHSteps(password:)`` —
    /// which is the one that actually matters for bug #4: it
    /// confirms Setup Assistant is fully dismissed and the Desktop
    /// responded to Option+Space *before* "Terminal" gets typed
    /// into whatever has focus.
    private static func finalScreensSteps() -> [BootStep] {
        [
            BootStep(delay: 10, action: shiftTab),  // Analytics
            BootStep(delay: 0, action: space),
            BootStep(delay: 10, action: tab),        // Screen Time
            BootStep(delay: 0, action: space),
            BootStep(delay: 10, action: tab),        // Siri (two-step)
            BootStep(delay: 0, action: space),
            BootStep(delay: 0, action: shiftTab),
            BootStep(delay: 0, action: space),
            BootStep(delay: 10, action: shiftTab),  // Choose Look
            BootStep(delay: 0, action: space),
            BootStep(delay: 10, action: tab),        // Auto Update
            BootStep(delay: 0, action: space),
            BootStep(delay: 10, action: space),      // Welcome to Mac
            BootStep(delay: 0, action: voiceover),   // Disable VoiceOver
        ]
    }

    /// Open Terminal via Spotlight and enable SSH.
    ///
    /// This is where bug #4 (blind automation reporting success
    /// while `sshd` was never actually enabled) traced back to: a
    /// desynchronized Option+Space or a "Terminal" that never
    /// actually landed in a Spotlight search field means every
    /// keystroke after it — including the `systemsetup` call this
    /// function exists to run — types into the void. Two gates fix
    /// that: `expectScreen` on Spotlight's own search-field text
    /// confirms the shortcut actually opened Spotlight before
    /// "Terminal" is typed, and `expectScreen` on Terminal.app's
    /// "Last login" startup banner (printed on every new shell
    /// session — stable across macOS versions and independent of
    /// system locale, since it's generated by `login(1)`, not
    /// Setup-Assistant UI copy) confirms a real shell prompt exists
    /// before the `sudo` command is typed.
    ///
    /// Option+Space itself keeps no pre-delay: it's a global
    /// shortcut, not text typed into a specific field, so it's safe
    /// to send immediately — what matters is gating on its *effect*
    /// before proceeding.
    private static func enableSSHSteps(password: String) -> [BootStep] {
        [
            BootStep(delay: 0, action: .shortcut(.space, modifiers: [.option])),
            BootStep(delay: 0, action: .expectScreen(
                containsAny: ["Spotlight Search", "Spotlight"],
                timeout: 60
            )),
            BootStep(delay: 0, action: .text("Terminal")),
            BootStep(delay: 0, action: enter),
            BootStep(delay: 0, action: .expectScreen(containsAny: ["Last login"], timeout: 60)),
            BootStep(delay: 0, action: .text("sudo systemsetup -setremotelogin on")),
            BootStep(delay: 0, action: enter),
            BootStep(delay: 5, action: .text(password)),
            BootStep(delay: 0, action: enter),
        ]
    }

    // MARK: - Zero-Touch Provisioner Install

    /// The guest-side mount point for the per-VM provisioning
    /// share. Must match `MOUNT_POINT` in
    /// `Resources/SpookProvisioner/spook-provision-runner.sh` —
    /// that script's `mount_virtiofs` call (run by the installed
    /// LaunchDaemon on every later boot) has to find the share at
    /// the exact path this one-time manual mount uses.
    ///
    /// `SpooktacularApplication` sits below
    /// `SpooktacularInfrastructureApple` in the module graph (see
    /// `Package.swift`), so this can't import
    /// `VirtualMachineBundle` and reuse its constant directly —
    /// the path is duplicated here rather than shared.
    private static let provisionMountPoint = "/Library/Application Support/Spooktacular/provision"

    /// The virtio-fs tag for the provisioning share, announced to
    /// every macOS guest by
    /// `VirtualMachineConfiguration.applyProvisioning(from:to:)`.
    /// Must match `VirtualMachineBundle.provisionShareTag` — see
    /// ``provisionMountPoint`` for why it's a literal instead of
    /// an imported symbol.
    private static let provisionShareTag = "spook-provision"

    /// Mounts the provisioning share and installs
    /// `Spooktacular Provisioner.pkg` from it, all inside the
    /// Terminal session ``enableSSHSteps(password:)`` opened.
    ///
    /// The host stages the pkg into the VM bundle's `provision/`
    /// directory (see `Create.swift`) before Setup Assistant
    /// automation starts; every macOS guest already auto-attaches
    /// that directory as the ``provisionShareTag`` virtio-fs share
    /// on boot (`VirtualMachineConfiguration.applyProvisioning`),
    /// so by the time these steps run the pkg is sitting on the
    /// share, waiting to be mounted.
    ///
    /// Three commands, typed and returned in order:
    ///
    /// 1. `sudo mkdir -p <mount point>` — `mkdir(1)`'s `-p` makes
    ///    the call idempotent if the directory already exists.
    /// 2. `sudo mount_virtiofs <tag> <mount point>` —
    ///    `mount_virtiofs(8)` takes exactly `fs_tag directory`
    ///    (see its man page); this is the same primitive the
    ///    installed daemon's runner script uses on every later
    ///    boot, just invoked once by hand here.
    /// 3. `sudo installer -pkg <mount point>/<pkg> -target /` —
    ///    `installer(8)` "requires root privileges to run" and
    ///    installs "to a specified domain or volume"; `-target /`
    ///    selects the running system volume (the `LocalSystem`
    ///    domain the pkg's payload paths — `/Library/LaunchDaemons/`,
    ///    `/usr/local/libexec/` — are already rooted at). Its
    ///    postinstall (`Resources/SpookProvisioner/postinstall`)
    ///    runs `launchctl bootstrap` synchronously before
    ///    `installer` exits, so the daemon is live before the
    ///    guest's next boot without a reboot in between.
    ///
    /// Each `sudo` call is followed by a password entry, mirroring
    /// ``enableSSHSteps(password:)`` exactly. Per `sudoers(5)`,
    /// the default `timestamp_timeout` is 5 minutes with
    /// `timestamp_type tty`, so the ticket the `systemsetup` sudo
    /// call created moments earlier should still cover these
    /// three calls in the same terminal — but blind keystroke
    /// automation can't read the screen to confirm a password
    /// prompt actually appeared before typing into it. Retyping
    /// the password after every `sudo` is the same defensive
    /// choice ``enableSSHSteps(password:)`` already makes for its
    /// one `sudo` call, generalized to three: if the ticket is
    /// still valid the extra keystrokes land on an ordinary shell
    /// prompt as a harmless unrecognized command, but if it
    /// somehow wasn't, the sequence still supplies the password
    /// the prompt is waiting on instead of stalling forever.
    ///
    /// A trailing 20-second wait gives `installer` — including its
    /// synchronous postinstall — time to finish before the caller
    /// (`Create.swift`'s `automateSetupAssistant`) starts polling
    /// for SSH.
    ///
    /// A screen gate opens this function, confirming the shell
    /// prompt from the `systemsetup` call in
    /// ``enableSSHSteps(password:)`` actually returned — i.e. the
    /// terminal is idle and ready for the next command — before
    /// `sudo mkdir` is typed. macOS's default shell prompt includes
    /// the logged-in account name (`zsh`'s default `PS1`; see
    /// `/etc/zshrc` and `man zshmisc` PROMPT EXPANSION), so the
    /// account's own `username` — already known and unique to this
    /// automation run, not a guess at Setup Assistant UI copy — is a
    /// reliable, locale-independent marker for "the prompt is back."
    private static func installProvisionerSteps(username: String, password: String) -> [BootStep] {
        let pkgPath = "\(provisionMountPoint)/\(AppBundleBootstrapTemplate.provisionerPkgFileName)"

        func sudoStep(_ command: String) -> [BootStep] {
            [
                BootStep(delay: 5, action: .text(command)),
                BootStep(delay: 0, action: enter),
                BootStep(delay: 5, action: .text(password)),
                BootStep(delay: 0, action: enter),
            ]
        }

        return [BootStep(delay: 0, action: .expectScreen(containsAny: [username], timeout: 60))]
            + sudoStep("sudo mkdir -p '\(provisionMountPoint)'")
            + sudoStep("sudo mount_virtiofs \(provisionShareTag) '\(provisionMountPoint)'")
            + sudoStep("sudo installer -pkg '\(pkgPath)' -target /")
            + [BootStep(delay: 20, action: .wait(0))]
    }

}
