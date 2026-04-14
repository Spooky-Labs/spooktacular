import AppKit
import os
import SpooktacularKit
@preconcurrency import Virtualization

/// AppKit-based ``KeyboardDriver`` that delivers keyboard events
/// to a `VZVirtualMachine` through an offscreen `VZVirtualMachineView`.
///
/// `VZKeyboardDriver` creates an offscreen `NSWindow` containing a
/// `VZVirtualMachineView`, then synthesizes `NSEvent` keyboard events
/// and sends them to the view. The Virtualization framework routes
/// these events to the guest OS through the VM's
/// `VZMacKeyboardConfiguration`.
///
/// ## How It Works
///
/// 1. An offscreen `NSWindow` is created with a `VZVirtualMachineView`
///    as its content view. The view is connected to the VM.
/// 2. The window is made key (required for keyboard event delivery)
///    but positioned offscreen so it is not visible.
/// 3. `sendKey(_:modifiers:)` and `sendText(_:)` synthesize
///    `NSEvent` key-down/key-up pairs and deliver them to the view.
///
/// This approach matches the technique used by
/// [Tart](https://github.com/cirruslabs/tart) for Packer `boot_command`
/// sequences, which has been proven reliable across macOS 13 through 26.
///
/// ## Requirements
///
/// - `NSApplication.shared` must exist (the process needs an AppKit
///   event loop). The initializer calls
///   `NSApplication.shared.setActivationPolicy(.accessory)` to ensure
///   this.
/// - Accessibility permissions are **not** required because events are
///   sent directly to the view, not through the system event tap.
///
/// ## Thread Safety
///
/// All methods are `@MainActor` because `NSWindow`,
/// `VZVirtualMachineView`, and `VZVirtualMachine` are main-thread-only.
@MainActor
public final class VZKeyboardDriver: KeyboardDriver, @unchecked Sendable {

    private let window: NSWindow
    private let vmView: VZVirtualMachineView

    /// Creates a keyboard driver connected to the given virtual machine.
    ///
    /// Sets up the AppKit event loop, creates an offscreen
    /// `VZVirtualMachineView`, and makes it the key window for
    /// keyboard event delivery.
    ///
    /// - Parameter virtualMachine: A running `VZVirtualMachine` instance.
    public init(virtualMachine: VZVirtualMachine) {
        // Ensure AppKit event loop is available for keyboard delivery.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let view = VZVirtualMachineView()
        view.virtualMachine = virtualMachine
        view.capturesSystemKeys = true

        let win = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 1920, height: 1200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.contentView = view
        win.makeKeyAndOrderFront(nil)

        self.window = win
        self.vmView = view

        Log.provision.debug("VZKeyboardDriver: offscreen automation window created")
    }

    deinit {
        // NSWindow and VZVirtualMachineView must be torn down on main thread,
        // but deinit runs on whatever thread drops the last reference.
        // The window will be cleaned up when it goes out of scope; we call
        // orderOut to hide it immediately if still visible.
        MainActor.assumeIsolated {
            window.orderOut(nil)
            Log.provision.debug("VZKeyboardDriver: offscreen automation window closed")
        }
    }

    // MARK: - KeyboardDriver

    public func sendKey(_ keyCode: KeyCode, modifiers: [Modifier]) async throws {
        let cgCode = keyCode.cgKeyCode
        let flags = NSEvent.ModifierFlags(modifiers)
        sendNSEvent(
            keyCode: cgCode,
            modifierFlags: flags,
            characters: keyCode.characterString,
            to: vmView
        )
    }

    public func sendText(_ text: String) async throws {
        for character in text {
            guard let mapping = characterToKeyMapping(character) else {
                throw SetupAutomationExecutorError.unmappableCharacter(character)
            }
            sendNSEvent(
                keyCode: mapping.keyCode,
                modifierFlags: mapping.modifiers,
                characters: String(character),
                to: vmView
            )
        }
    }

    // MARK: - NSEvent Synthesis

    /// Sends a key-down/key-up pair to the view.
    ///
    /// Uses `NSEvent.keyEvent(with:)` to create synthetic keyboard
    /// events and delivers them via the view's `keyDown(_:)` and
    /// `keyUp(_:)` methods. This bypasses the system event tap
    /// entirely, so no accessibility permissions are needed.
    private func sendNSEvent(
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
