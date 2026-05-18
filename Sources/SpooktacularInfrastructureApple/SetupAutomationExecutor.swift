import Foundation
import SpooktacularCore
import SpooktacularApplication
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
/// to a running `VZVirtualMachine` through a ``KeyboardDriver``.
///
/// `SetupAutomationExecutor` iterates over a sequence of ``BootStep``s,
/// waiting for each step's delay, then dispatching the keyboard action
/// through the provided ``KeyboardDriver`` implementation.
///
/// ## How It Works
///
/// 1. The caller provides a ``KeyboardDriver`` that knows how to
///    deliver keyboard events to the VM (e.g., via an offscreen
///    `NSWindow` with a `VZVirtualMachineView`).
/// 2. For each ``BootStep``, the executor waits for the step's delay,
///    then sends the action through the driver.
/// 3. After all steps complete, control returns to the caller.
///
/// This approach matches the technique used by
/// [Tart](https://github.com/cirruslabs/tart) for Packer `boot_command`
/// sequences, which has been proven reliable across macOS 13 through 26.
///
/// ## Example
///
/// ```swift
/// let driver = VZKeyboardDriver(virtualMachine: vm)
/// let steps = SetupAutomation.sequence(for: 15)
/// try await SetupAutomationExecutor.run(steps: steps, using: driver)
/// ```
///
/// ## Thread Safety
///
/// All methods are `@MainActor` because `VZVirtualMachine` and
/// keyboard event delivery are main-thread-only.
public enum SetupAutomationExecutor {

    // MARK: - Public API

    /// Executes a sequence of ``BootStep``s by sending keyboard events
    /// through the given driver.
    ///
    /// Iterates over each step, waits for its delay, then dispatches
    /// the action through the ``KeyboardDriver``. The method returns
    /// after the last step completes.
    ///
    /// When a ``ScreenReader`` is provided, `.waitForText` and
    /// `.clickText` actions use Vision OCR to detect screen content.
    /// Without a screen reader, `.waitForText` falls back to a fixed
    /// delay and `.clickText` is skipped. All existing timing-based
    /// sequences continue to work without a screen reader.
    ///
    /// - Parameters:
    ///   - steps: The ordered boot step sequence from
    ///     ``SetupAutomation/sequence(for:username:password:)``.
    ///   - driver: A ``KeyboardDriver`` that delivers keyboard events
    ///     to the virtual machine.
    ///   - screenReader: An optional ``ScreenReader`` for screen-aware
    ///     actions. Pass `nil` to use timing-based fallbacks.
    /// - Throws: ``SetupAutomationExecutorError/unmappableCharacter(_:)``
    ///   if a text character cannot be converted to a key code, or any
    ///   error thrown by the driver or screen reader.
    @MainActor
    public static func run(
        steps: [BootStep],
        using driver: any KeyboardDriver,
        screenReader: (any ScreenReader)? = nil
    ) async throws {
        Log.provision.info("Starting Setup Assistant automation (\(steps.count) steps)")
        if screenReader != nil {
            Log.provision.info("Screen reader available — screen-aware actions enabled")
        }

        for (index, step) in steps.enumerated() {
            if step.delay > 0 {
                Log.provision.debug(
                    "Step \(index + 1)/\(steps.count): waiting \(step.delay, privacy: .public)s"
                )
                try await Task.sleep(for: .seconds(step.delay))
            }

            try await performAction(
                step.action,
                using: driver,
                screenReader: screenReader,
                stepIndex: index,
                totalSteps: steps.count
            )
        }

        Log.provision.notice("Setup Assistant automation completed (\(steps.count) steps)")
    }

    // MARK: - Action Dispatch

    /// Performs a single ``BootAction`` by sending the appropriate
    /// keyboard events through the driver.
    ///
    /// - Parameters:
    ///   - action: The action to perform.
    ///   - driver: The ``KeyboardDriver`` to send events through.
    ///   - screenReader: An optional ``ScreenReader`` for screen-aware actions.
    ///   - stepIndex: The zero-based index for logging.
    ///   - totalSteps: The total step count for logging.
    @MainActor
    private static func performAction(
        _ action: BootAction,
        using driver: any KeyboardDriver,
        screenReader: (any ScreenReader)?,
        stepIndex: Int,
        totalSteps: Int
    ) async throws {
        switch action {
        case .text(let string):
            Log.provision.debug(
                "Step \(stepIndex + 1)/\(totalSteps): typing \(string.count) character(s)"
            )
            try await driver.sendText(string)

        case .key(let keyCode):
            Log.provision.debug(
                "Step \(stepIndex + 1)/\(totalSteps): key \(keyCode.rawValue, privacy: .public)"
            )
            try await driver.sendKey(keyCode, modifiers: [])

        case .shortcut(let keyCode, modifiers: let modifiers):
            let modNames = modifiers.map(\.rawValue).joined(separator: "+")
            Log.provision.debug(
                "Step \(stepIndex + 1)/\(totalSteps): shortcut \(modNames, privacy: .public)+\(keyCode.rawValue, privacy: .public)"
            )
            try await driver.sendKey(keyCode, modifiers: modifiers)

        case .wait(let duration):
            Log.provision.debug(
                "Step \(stepIndex + 1)/\(totalSteps): extra wait \(duration, privacy: .public)s"
            )
            try await Task.sleep(for: .seconds(duration))

        case .waitForText(let text, let timeout):
            guard let reader = screenReader else {
                Log.provision.warning(
                    "No screen reader — falling back to fixed delay for '\(text, privacy: .public)'"
                )
                try await Task.sleep(for: .seconds(timeout))
                return
            }
            Log.provision.debug(
                "Step \(stepIndex + 1)/\(totalSteps): waiting for text '\(text, privacy: .public)'"
            )
            _ = try await reader.waitForText(text, timeout: timeout)

        case .clickText(let text, let timeout):
            guard let reader = screenReader else {
                Log.provision.warning(
                    "No screen reader — cannot click '\(text, privacy: .public)', skipping"
                )
                return
            }
            Log.provision.debug(
                "Step \(stepIndex + 1)/\(totalSteps): clicking text '\(text, privacy: .public)'"
            )
            let match = try await reader.waitForText(text, timeout: timeout)
            // Convert Vision bounding box (bottom-left origin, 0-1) to
            // view click coordinates (top-left origin, 0-1).
            let clickX = match.boundingBox.midX
            let clickY = 1.0 - match.boundingBox.midY
            try await driver.clickAt(x: clickX, y: clickY)
        }
    }
}
