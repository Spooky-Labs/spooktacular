import Foundation

/// Delivers keyboard events to a running virtual machine.
///
/// Implement this protocol to provide platform-specific keyboard
/// input to `VZVirtualMachine`. The CLI provides ``VZKeyboardDriver``
/// (AppKit-based), the GUI can use its existing `VZVirtualMachineView`.
///
/// ## Conformance Requirements
///
/// Both methods are `@MainActor` because `VZVirtualMachine` and
/// `VZVirtualMachineView` must be accessed on the main thread.
///
/// ## Example
///
/// ```swift
/// let driver = VZKeyboardDriver(virtualMachine: vm)
/// try await driver.sendKey(.returnKey, modifiers: [])
/// try await driver.sendText("admin")
/// ```
public protocol KeyboardDriver: Sendable {

    /// Sends a single key press with optional modifier keys.
    ///
    /// Implementations should generate a key-down event followed by
    /// a key-up event for the given key code, with the specified
    /// modifier keys held down during the press.
    ///
    /// - Parameters:
    ///   - keyCode: The virtual key to press.
    ///   - modifiers: Modifier keys to hold during the press.
    @MainActor func sendKey(_ keyCode: KeyCode, modifiers: [Modifier]) async throws

    /// Types a string by sending key events for each character.
    ///
    /// Implementations should map each character to its virtual key
    /// code and required modifiers (e.g., Shift for uppercase), then
    /// send a key-down/key-up pair for each.
    ///
    /// - Parameter text: The string to type.
    /// - Throws: ``SetupAutomationExecutorError/unmappableCharacter(_:)``
    ///   if a character cannot be converted to a key code.
    @MainActor func sendText(_ text: String) async throws

    /// Sends a mouse click at normalized coordinates.
    ///
    /// Coordinates are in the range 0--1, where (0, 0) is the
    /// top-left corner and (1, 1) is the bottom-right corner of
    /// the VM display.
    ///
    /// Implementations should synthesize a mouse-down/mouse-up pair
    /// at the corresponding pixel position within the VM view.
    ///
    /// - Parameters:
    ///   - x: Horizontal position (0 = left, 1 = right).
    ///   - y: Vertical position (0 = top, 1 = bottom).
    @MainActor func clickAt(x: Double, y: Double) async throws
}
