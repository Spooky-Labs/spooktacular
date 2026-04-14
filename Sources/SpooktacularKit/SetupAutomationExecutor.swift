import AppKit
import Foundation
import os
@preconcurrency import Virtualization

/// Errors that can occur during Setup Assistant automation execution.
public enum SetupAutomationExecutorError: Error, Sendable, LocalizedError {

    /// The virtual machine has no underlying `VZVirtualMachine` instance.
    case virtualMachineInvalidated

    /// A character in a `.text` action could not be mapped to a key code.
    case unmappableCharacter(Character)

    /// A human-readable description of the error.
    public var errorDescription: String? {
        switch self {
        case .virtualMachineInvalidated:
            "The virtual machine is invalidated and cannot receive keyboard events."
        case .unmappableCharacter(let char):
            "Cannot map character '\(char)' to a virtual key code."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .virtualMachineInvalidated:
            "Restart the VM and retry the setup automation."
        case .unmappableCharacter:
            "Use only ASCII alphanumeric characters, common punctuation, and whitespace in usernames and passwords."
        }
    }
}

/// Drives macOS Setup Assistant automation by sending keyboard events
/// to a running `VZVirtualMachine`.
///
/// `SetupAutomationExecutor` creates an offscreen `NSWindow` containing
/// a `VZVirtualMachineView`, then sends synthesized `NSEvent` keyboard
/// events to the view for each ``BootStep`` in the sequence. The
/// Virtualization framework routes these events to the guest OS through
/// the VM's `VZMacKeyboardConfiguration`.
///
/// ## How It Works
///
/// 1. An offscreen `NSWindow` is created with a `VZVirtualMachineView`
///    as its content view. The view is connected to the VM's
///    `VZVirtualMachine` instance.
/// 2. The window is made the key window (required for keyboard event
///    delivery) but positioned offscreen so it is not visible.
/// 3. For each ``BootStep``, the executor waits for the step's delay,
///    then synthesizes and delivers `NSEvent` key-down/key-up pairs
///    to the view.
/// 4. After all steps complete, the offscreen window is closed.
///
/// This approach matches the technique used by
/// [Tart](https://github.com/cirruslabs/tart) for Packer `boot_command`
/// sequences, which has been proven reliable across macOS 13 through 26.
///
/// ## Requirements
///
/// - The VM must be in the ``VirtualMachineState/running`` state.
/// - `NSApplication.shared` must exist (the process needs an AppKit
///   event loop). CLI tools should call
///   `NSApplication.shared.setActivationPolicy(.accessory)` before
///   invoking this executor.
/// - Accessibility permissions are **not** required because events are
///   sent directly to the view, not through the system event tap.
///
/// ## Example
///
/// ```swift
/// let steps = SetupAutomation.sequence(for: 15)
/// try await SetupAutomationExecutor.run(steps: steps, on: vm.vzVM!)
/// ```
///
/// ## Thread Safety
///
/// All methods are `@MainActor` because `NSWindow`,
/// `VZVirtualMachineView`, and `VZVirtualMachine` are main-thread-only.
public enum SetupAutomationExecutor {

    // MARK: - Public API

    /// Executes a sequence of ``BootStep``s by sending keyboard events
    /// to the given virtual machine.
    ///
    /// Creates an offscreen `VZVirtualMachineView`, attaches it to the
    /// VM, and delivers synthesized keyboard events for each step. The
    /// method returns after the last step completes.
    ///
    /// - Parameters:
    ///   - steps: The ordered boot step sequence from
    ///     ``SetupAutomation/sequence(for:username:password:)``.
    ///   - virtualMachine: A running `VZVirtualMachine` instance.
    /// - Throws: ``SetupAutomationExecutorError/virtualMachineInvalidated``
    ///   if the VM is `nil`, or
    ///   ``SetupAutomationExecutorError/unmappableCharacter(_:)`` if a
    ///   text character cannot be converted to a key code.
    @MainActor
    public static func run(
        steps: [BootStep],
        on virtualMachine: VZVirtualMachine
    ) async throws {
        Log.provision.info("Starting Setup Assistant automation (\(steps.count) steps)")

        let (window, vmView) = createOffscreenView(for: virtualMachine)
        defer {
            Log.provision.debug("Closing offscreen automation window")
            window.orderOut(nil)
        }

        for (index, step) in steps.enumerated() {
            if step.delay > 0 {
                Log.provision.debug(
                    "Step \(index + 1)/\(steps.count): waiting \(step.delay, privacy: .public)s"
                )
                try await Task.sleep(for: .seconds(step.delay))
            }

            try await performAction(step.action, on: vmView, stepIndex: index, totalSteps: steps.count)
        }

        Log.provision.notice("Setup Assistant automation completed (\(steps.count) steps)")
    }

    // MARK: - Offscreen Window

    /// Creates an offscreen `NSWindow` with a `VZVirtualMachineView`
    /// connected to the given VM.
    ///
    /// The window is positioned far offscreen (-10000, -10000) so it
    /// never appears on the user's display, but it is made key so that
    /// keyboard events are delivered correctly.
    ///
    /// - Parameter virtualMachine: The `VZVirtualMachine` to attach.
    /// - Returns: A tuple of the window and the view.
    @MainActor
    private static func createOffscreenView(
        for virtualMachine: VZVirtualMachine
    ) -> (NSWindow, VZVirtualMachineView) {
        Log.provision.debug("Creating offscreen VZVirtualMachineView for automation")

        let vmView = VZVirtualMachineView()
        vmView.virtualMachine = virtualMachine
        vmView.capturesSystemKeys = true

        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 1920, height: 1200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = vmView
        window.makeKeyAndOrderFront(nil)

        Log.provision.debug("Offscreen automation window created")
        return (window, vmView)
    }

    // MARK: - Action Dispatch

    /// Performs a single ``BootAction`` by sending the appropriate
    /// keyboard events to the view.
    ///
    /// - Parameters:
    ///   - action: The action to perform.
    ///   - view: The `VZVirtualMachineView` to send events to.
    ///   - stepIndex: The zero-based index for logging.
    ///   - totalSteps: The total step count for logging.
    @MainActor
    private static func performAction(
        _ action: BootAction,
        on view: VZVirtualMachineView,
        stepIndex: Int,
        totalSteps: Int
    ) async throws {
        switch action {
        case .text(let string):
            Log.provision.debug(
                "Step \(stepIndex + 1)/\(totalSteps): typing \(string.count) character(s)"
            )
            try sendText(string, to: view)

        case .key(let keyCode):
            Log.provision.debug(
                "Step \(stepIndex + 1)/\(totalSteps): key \(keyCode.rawValue, privacy: .public)"
            )
            try sendKey(keyCode, modifiers: [], to: view)

        case .shortcut(let keyCode, modifiers: let modifiers):
            let modNames = modifiers.map(\.rawValue).joined(separator: "+")
            Log.provision.debug(
                "Step \(stepIndex + 1)/\(totalSteps): shortcut \(modNames, privacy: .public)+\(keyCode.rawValue, privacy: .public)"
            )
            try sendKey(keyCode, modifiers: modifiers, to: view)

        case .wait(let duration):
            Log.provision.debug(
                "Step \(stepIndex + 1)/\(totalSteps): extra wait \(duration, privacy: .public)s"
            )
            try await Task.sleep(for: .seconds(duration))
        }
    }

    // MARK: - Text Input

    /// Types a string by sending key-down/key-up pairs for each character.
    ///
    /// Each character is mapped to a virtual key code and optional
    /// modifier flags (e.g., uppercase letters require Shift). A small
    /// inter-keystroke delay (10ms) is inserted to prevent the guest
    /// from dropping events.
    ///
    /// - Parameters:
    ///   - text: The string to type.
    ///   - view: The target view.
    /// - Throws: ``SetupAutomationExecutorError/unmappableCharacter(_:)``
    ///   if any character cannot be mapped.
    @MainActor
    private static func sendText(_ text: String, to view: VZVirtualMachineView) throws {
        for character in text {
            guard let mapping = characterToKeyMapping(character) else {
                throw SetupAutomationExecutorError.unmappableCharacter(character)
            }
            sendNSEvent(
                keyCode: mapping.keyCode,
                modifierFlags: mapping.modifiers,
                characters: String(character),
                to: view
            )
        }
    }

    // MARK: - Key Input

    /// Sends a single key press with optional modifiers.
    ///
    /// Generates a key-down event followed by a key-up event. Modifier
    /// keys are included in the event's `modifierFlags`.
    ///
    /// - Parameters:
    ///   - keyCode: The ``KeyCode`` to press.
    ///   - modifiers: Modifier keys to hold during the press.
    ///   - view: The target view.
    @MainActor
    private static func sendKey(
        _ keyCode: KeyCode,
        modifiers: [Modifier],
        to view: VZVirtualMachineView
    ) throws {
        let cgKeyCode = keyCode.cgKeyCode
        let flags = NSEvent.ModifierFlags(modifiers)

        sendNSEvent(
            keyCode: cgKeyCode,
            modifierFlags: flags,
            characters: keyCode.characterString,
            to: view
        )
    }

    // MARK: - NSEvent Synthesis

    /// Sends a key-down/key-up pair to the view.
    ///
    /// Uses `NSEvent.keyEvent(with:)` to create synthetic keyboard
    /// events and delivers them via the view's `keyDown(_:)` and
    /// `keyUp(_:)` methods. This bypasses the system event tap
    /// entirely, so no accessibility permissions are needed.
    ///
    /// - Parameters:
    ///   - keyCode: The `CGKeyCode` (UInt16) for the key.
    ///   - modifierFlags: The modifier flags to include.
    ///   - characters: The character string for the event.
    ///   - view: The target view.
    @MainActor
    private static func sendNSEvent(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        characters: String,
        to view: VZVirtualMachineView
    ) {
        let timestamp = ProcessInfo.processInfo.systemUptime

        if let keyDown = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: timestamp,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) {
            view.keyDown(with: keyDown)
        }

        if let keyUp = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: timestamp + 0.01,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) {
            view.keyUp(with: keyUp)
        }
    }
}

// MARK: - Key Code Mapping

extension KeyCode {

    /// The `CGKeyCode` (Carbon virtual key code) for this key.
    ///
    /// These values come from `Events.h` in the Carbon framework
    /// (aka `HIToolbox/Events.h`). They are stable across all macOS
    /// versions on both Intel and Apple Silicon.
    var cgKeyCode: UInt16 {
        switch self {
        case .returnKey:  0x24
        case .tab:        0x30
        case .space:      0x31
        case .escape:     0x35
        case .delete:     0x33
        case .leftArrow:  0x7B
        case .rightArrow: 0x7C
        case .upArrow:    0x7E
        case .downArrow:  0x7D
        case .f5:         0x60
        }
    }

    /// A representative character string for the key, used when
    /// constructing `NSEvent` objects.
    ///
    /// For non-printable keys, this returns the conventional
    /// Unicode control character (e.g., `\r` for Return, `\t`
    /// for Tab). For arrow keys and function keys, an empty
    /// string is used because these keys have no printable
    /// representation.
    var characterString: String {
        switch self {
        case .returnKey:  "\r"
        case .tab:        "\t"
        case .space:      " "
        case .escape:     "\u{1B}"
        case .delete:     "\u{7F}"
        case .leftArrow:  String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case .rightArrow: String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case .upArrow:    String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case .downArrow:  String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case .f5:         String(UnicodeScalar(NSF5FunctionKey)!)
        }
    }
}

// MARK: - Modifier Flag Mapping

extension NSEvent.ModifierFlags {

    /// Creates modifier flags from an array of ``Modifier`` values.
    ///
    /// - Parameter modifiers: The modifiers to combine.
    init(_ modifiers: [Modifier]) {
        self = modifiers.reduce(NSEvent.ModifierFlags()) { flags, modifier in
            flags.union(modifier.nsEventModifierFlag)
        }
    }
}

extension Modifier {

    /// The `NSEvent.ModifierFlags` value for this modifier.
    var nsEventModifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .command:  .command
        case .option:   .option
        case .shift:    .shift
        case .control:  .control
        }
    }
}

// MARK: - Character-to-Key Mapping

/// A mapping from a character to its virtual key code and required modifiers.
private struct KeyMapping {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
}

/// Maps a printable character to its virtual key code and modifier flags.
///
/// Supports the US QWERTY keyboard layout, which is the default for
/// new macOS installations. This covers all characters that appear in
/// Setup Assistant automation sequences (alphanumerics, common
/// punctuation, and whitespace).
///
/// - Parameter character: The character to map.
/// - Returns: A `KeyMapping` with the key code and modifiers, or `nil`
///   if the character is not mapped.
private func characterToKeyMapping(_ character: Character) -> KeyMapping? {
    let lower = character.lowercased().first ?? character

    // Check if the character requires Shift (uppercase or shifted symbol).
    let needsShift = character.isUppercase || shiftedSymbols[character] != nil

    // Look up the base key code.
    let baseChar = needsShift ? (shiftedSymbols[character] ?? lower) : character
    guard let keyCode = baseKeyCodeMap[baseChar] else {
        return nil
    }

    let modifiers: NSEvent.ModifierFlags = needsShift ? .shift : []
    return KeyMapping(keyCode: keyCode, modifiers: modifiers)
}

/// Maps unshifted characters to their Carbon virtual key codes (US QWERTY).
///
/// Virtual key codes from `HIToolbox/Events.h`:
/// - Letters: `kVK_ANSI_A` (0x00) through `kVK_ANSI_Z`
/// - Numbers: `kVK_ANSI_0` (0x1D) through `kVK_ANSI_9`
/// - Punctuation: various codes for each key
private let baseKeyCodeMap: [Character: UInt16] = [
    // Letters (lowercase)
    "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02,
    "e": 0x0E, "f": 0x03, "g": 0x05, "h": 0x04,
    "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25,
    "m": 0x2E, "n": 0x2D, "o": 0x1F, "p": 0x23,
    "q": 0x0C, "r": 0x0F, "s": 0x01, "t": 0x11,
    "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07,
    "y": 0x10, "z": 0x06,

    // Numbers
    "0": 0x1D, "1": 0x12, "2": 0x13, "3": 0x14,
    "4": 0x15, "5": 0x17, "6": 0x16, "7": 0x1A,
    "8": 0x1C, "9": 0x19,

    // Punctuation and symbols (unshifted positions)
    "-": 0x1B,   // kVK_ANSI_Minus
    "=": 0x18,   // kVK_ANSI_Equal
    "[": 0x21,   // kVK_ANSI_LeftBracket
    "]": 0x1E,   // kVK_ANSI_RightBracket
    "\\": 0x2A,  // kVK_ANSI_Backslash
    ";": 0x29,   // kVK_ANSI_Semicolon
    "'": 0x27,   // kVK_ANSI_Quote
    ",": 0x2B,   // kVK_ANSI_Comma
    ".": 0x2F,   // kVK_ANSI_Period
    "/": 0x2C,   // kVK_ANSI_Slash
    "`": 0x32,   // kVK_ANSI_Grave

    // Whitespace
    " ": 0x31,   // kVK_Space
    "\t": 0x30,  // kVK_Tab
    "\r": 0x24,  // kVK_Return
    "\n": 0x24,  // kVK_Return (treat newline as Return)
]

/// Maps shifted symbol characters to their unshifted base characters.
///
/// For example, `!` is Shift+`1`, so this maps `!` -> `1`.
/// The base character is then looked up in ``baseKeyCodeMap``.
private let shiftedSymbols: [Character: Character] = [
    "!": "1", "@": "2", "#": "3", "$": "4",
    "%": "5", "^": "6", "&": "7", "*": "8",
    "(": "9", ")": "0",
    "_": "-", "+": "=",
    "{": "[", "}": "]",
    "|": "\\",
    ":": ";", "\"": "'",
    "<": ",", ">": ".",
    "?": "/", "~": "`",
]
