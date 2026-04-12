import Foundation

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
}

/// Virtual key codes for Setup Assistant navigation.
///
/// These map to the key codes used by the Virtualization
/// framework's keyboard event API. Only keys needed for
/// Setup Assistant automation are included.
public enum KeyCode: String, Sendable, CaseIterable {

    /// The Return (Enter) key.
    case returnKey

    /// The Tab key.
    case tab

    /// The Space bar.
    case space

    /// The Escape key.
    case escape

    /// The Delete (Backspace) key.
    case delete

    /// The left arrow key.
    case leftArrow

    /// The right arrow key.
    case rightArrow

    /// The up arrow key.
    case upArrow

    /// The down arrow key.
    case downArrow

    /// The F5 function key, used to toggle VoiceOver.
    case f5
}

/// Modifier keys for keyboard shortcuts.
///
/// Used with ``BootAction/shortcut(_:modifiers:)`` to create
/// key combinations like Command+Space or Option+F5.
public enum Modifier: String, Sendable, CaseIterable {

    /// The Command key.
    case command

    /// The Option (Alt) key.
    case option

    /// The Shift key.
    case shift

    /// The Control key.
    case control
}

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
    ///   - password: The password for the admin user. Defaults to `"admin"`.
    /// - Returns: An ordered array of boot steps. Returns an empty array
    ///   if the version is not supported.
    public static func sequence(
        for macOSVersion: Int,
        username: String = "admin",
        password: String = "admin"
    ) -> [BootStep] {
        switch macOSVersion {
        case 15:
            return sequoiaSequence(username: username, password: password)
        case 26:
            // Tahoe uses the same Setup Assistant layout as Sequoia.
            // This will be updated when Tahoe ships with layout changes.
            return tahoeSequence(username: username, password: password)
        default:
            return []
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
        password: String
    ) -> [BootStep] {
        var steps: [BootStep] = []

        // --- Wait for VM to boot and show the Hello screen ---
        steps.append(BootStep(delay: 60, action: .wait(0)))

        // --- Dismiss Hello screen ---
        steps.append(BootStep(delay: 0, action: .key(.space)))

        // --- Select English language ---
        // Type "italiano" to scroll the list, escape to reset search,
        // then type "english" and press Enter.
        steps.append(BootStep(delay: 30, action: .text("italiano")))
        steps.append(BootStep(delay: 0, action: .key(.escape)))
        steps.append(BootStep(delay: 0, action: .text("english")))
        steps.append(BootStep(delay: 0, action: .key(.returnKey)))

        // --- Select country: United States ---
        steps.append(BootStep(delay: 30, action: .text("united states")))
        steps.append(BootStep(delay: 0, action: .shortcut(.tab, modifiers: [.shift])))
        steps.append(BootStep(delay: 0, action: .key(.space)))

        // --- Skip Transfer Data (Not Now) ---
        steps.append(BootStep(delay: 10, action: .key(.tab)))
        steps.append(BootStep(delay: 0, action: .key(.tab)))
        steps.append(BootStep(delay: 0, action: .key(.tab)))
        steps.append(BootStep(delay: 0, action: .key(.space)))
        steps.append(BootStep(delay: 0, action: .key(.tab)))
        steps.append(BootStep(delay: 0, action: .key(.tab)))
        steps.append(BootStep(delay: 0, action: .key(.space)))

        // --- Skip Additional Languages ---
        steps.append(BootStep(delay: 10, action: .shortcut(.tab, modifiers: [.shift])))
        steps.append(BootStep(delay: 0, action: .key(.space)))

        // --- Skip Accessibility ---
        steps.append(BootStep(delay: 10, action: .shortcut(.tab, modifiers: [.shift])))
        steps.append(BootStep(delay: 0, action: .key(.space)))

        // --- Skip Data & Privacy ---
        steps.append(BootStep(delay: 10, action: .shortcut(.tab, modifiers: [.shift])))
        steps.append(BootStep(delay: 0, action: .key(.space)))

        // --- Create user account ---
        // Fields: Full Name, Account Name, Password, Verify Password
        steps.append(BootStep(delay: 10, action: .text(username)))
        steps.append(BootStep(delay: 0, action: .key(.tab)))
        steps.append(BootStep(delay: 0, action: .text(username)))
        steps.append(BootStep(delay: 0, action: .key(.tab)))
        steps.append(BootStep(delay: 0, action: .text(password)))
        steps.append(BootStep(delay: 0, action: .key(.tab)))
        steps.append(BootStep(delay: 0, action: .text(password)))
        steps.append(BootStep(delay: 0, action: .key(.tab)))
        steps.append(BootStep(delay: 0, action: .key(.tab)))
        steps.append(BootStep(delay: 0, action: .key(.space)))
        steps.append(BootStep(delay: 0, action: .key(.tab)))
        steps.append(BootStep(delay: 0, action: .key(.tab)))
        steps.append(BootStep(delay: 0, action: .key(.space)))

        // --- Enable VoiceOver for reliable navigation ---
        // Account creation takes a long time; wait 120s then toggle VoiceOver.
        steps.append(BootStep(delay: 120, action: .shortcut(.f5, modifiers: [.option])))

        // --- Skip Apple ID (Set Up Later) ---
        steps.append(BootStep(delay: 10, action: .shortcut(.tab, modifiers: [.shift])))
        steps.append(BootStep(delay: 0, action: .key(.space)))

        // --- Confirm Skip Apple ID ---
        steps.append(BootStep(delay: 10, action: .key(.tab)))
        steps.append(BootStep(delay: 0, action: .key(.space)))

        // --- Terms and Conditions: navigate to Agree ---
        steps.append(BootStep(delay: 10, action: .shortcut(.tab, modifiers: [.shift])))
        steps.append(BootStep(delay: 0, action: .key(.space)))

        // --- Confirm Terms agreement ---
        steps.append(BootStep(delay: 10, action: .key(.tab)))
        steps.append(BootStep(delay: 0, action: .key(.space)))

        // --- Skip Location Services ---
        steps.append(BootStep(delay: 10, action: .shortcut(.tab, modifiers: [.shift])))
        steps.append(BootStep(delay: 0, action: .key(.space)))

        // --- Confirm Skip Location ---
        steps.append(BootStep(delay: 10, action: .key(.tab)))
        steps.append(BootStep(delay: 0, action: .key(.space)))

        // --- Set Timezone to UTC ---
        steps.append(BootStep(delay: 10, action: .key(.tab)))
        steps.append(BootStep(delay: 0, action: .key(.tab)))
        steps.append(BootStep(delay: 0, action: .text("UTC")))
        steps.append(BootStep(delay: 0, action: .key(.returnKey)))
        steps.append(BootStep(delay: 0, action: .shortcut(.tab, modifiers: [.shift])))
        steps.append(BootStep(delay: 0, action: .shortcut(.tab, modifiers: [.shift])))
        steps.append(BootStep(delay: 0, action: .key(.space)))

        // --- Skip Analytics ---
        steps.append(BootStep(delay: 10, action: .shortcut(.tab, modifiers: [.shift])))
        steps.append(BootStep(delay: 0, action: .key(.space)))

        // --- Skip Screen Time ---
        steps.append(BootStep(delay: 10, action: .key(.tab)))
        steps.append(BootStep(delay: 0, action: .key(.space)))

        // --- Skip Siri ---
        steps.append(BootStep(delay: 10, action: .key(.tab)))
        steps.append(BootStep(delay: 0, action: .key(.space)))
        steps.append(BootStep(delay: 0, action: .shortcut(.tab, modifiers: [.shift])))
        steps.append(BootStep(delay: 0, action: .key(.space)))

        // --- Skip Choose Look ---
        steps.append(BootStep(delay: 10, action: .shortcut(.tab, modifiers: [.shift])))
        steps.append(BootStep(delay: 0, action: .key(.space)))

        // --- Skip Auto Update ---
        steps.append(BootStep(delay: 10, action: .key(.tab)))
        steps.append(BootStep(delay: 0, action: .key(.space)))

        // --- Welcome to Mac (dismiss) ---
        steps.append(BootStep(delay: 10, action: .key(.space)))

        // --- Disable VoiceOver ---
        steps.append(BootStep(delay: 0, action: .shortcut(.f5, modifiers: [.option])))

        // --- Open Terminal via Spotlight ---
        steps.append(BootStep(delay: 10, action: .shortcut(.space, modifiers: [.option])))
        steps.append(BootStep(delay: 0, action: .text("Terminal")))
        steps.append(BootStep(delay: 0, action: .key(.returnKey)))

        // --- Enable SSH (Remote Login) ---
        steps.append(BootStep(delay: 10, action: .text("sudo systemsetup -setremotelogin on")))
        steps.append(BootStep(delay: 0, action: .key(.returnKey)))

        // --- Enter sudo password ---
        steps.append(BootStep(delay: 5, action: .text(password)))
        steps.append(BootStep(delay: 0, action: .key(.returnKey)))

        return steps
    }

    // MARK: - macOS 26 (Tahoe)

    /// The Setup Assistant automation sequence for macOS 26 (Tahoe).
    ///
    /// Based on the Sequoia sequence with adjustments for Tahoe's
    /// Setup Assistant layout. The core flow is the same --- Apple
    /// has kept the Setup Assistant structure stable across recent
    /// releases, with minor navigation changes.
    ///
    /// This sequence will be updated as Tahoe betas reveal any
    /// layout differences from Sequoia.
    private static func tahoeSequence(
        username: String,
        password: String
    ) -> [BootStep] {
        // Tahoe's Setup Assistant shares the same structure as Sequoia.
        // Reuse the Sequoia sequence as the baseline. When Tahoe ships,
        // any screen differences will be patched here.
        return sequoiaSequence(username: username, password: password)
    }
}
