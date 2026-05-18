/// Virtual key codes for keyboard automation.
///
/// These map to the key codes used by the Virtualization
/// framework's keyboard event API.
public enum KeyCode: String, Sendable, CaseIterable {
    case returnKey
    case tab
    case space
    case escape
    case delete
    case leftArrow
    case rightArrow
    case upArrow
    case downArrow
    case f5
}

/// Modifier keys for keyboard shortcuts.
public enum Modifier: String, Sendable, CaseIterable {
    case command
    case option
    case shift
    case control
}
