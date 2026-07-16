import Foundation

/// Digs the real cause out of an `NSError` underlying-error chain.
///
/// Apple frameworks — Virtualization in particular — often surface a
/// generic top-level error ("An error occurred during installation.")
/// with the actionable cause buried one or more levels deep under
/// `NSUnderlyingErrorKey` ("The maximum number of running virtual
/// machines has been reached."). Presenting only the top-level
/// `localizedDescription` throws that information away, which is how
/// users end up staring at a message that names no cause and no fix.
///
/// ``composedMessage(for:)`` is the presentation-side counterpart to
/// typed pre-flight checks: pre-flights catch the failures we can
/// predict with precise typed errors, and this composer makes sure
/// the failures we *didn't* predict still surface whatever the
/// framework knew about the cause.
public enum ErrorCauseChain {

    /// Walks the `NSUnderlyingErrorKey` chain starting at `error`.
    ///
    /// - Parameter error: The top-level error.
    /// - Returns: The chain from the top-level error down to the
    ///   deepest underlying error, in order. Always contains at
    ///   least `error` itself. Defensive depth cap keeps a
    ///   pathological self-referencing chain from looping forever.
    public static func underlyingChain(of error: Error) -> [Error] {
        var chain: [Error] = [error]
        var current = error as NSError
        // Underlying chains in practice are 1-3 levels; 8 is a
        // generous cap that still guarantees termination if a
        // framework ever hands back a cyclic userInfo.
        for _ in 0..<8 {
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else {
                break
            }
            chain.append(underlying)
            current = underlying
        }
        return chain
    }

    /// The deepest underlying error's description, or `nil` when the
    /// chain has no deeper level than the error itself.
    public static func deepestDescription(of error: Error) -> String? {
        let chain = underlyingChain(of: error)
        guard chain.count > 1, let deepest = chain.last else { return nil }
        let description = deepest.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? nil : description
    }

    /// A user-facing message combining the top-level description with
    /// the deepest underlying cause when the two differ.
    ///
    /// "An error occurred during installation." becomes
    /// "An error occurred during installation. The maximum number of
    /// running virtual machines has been reached." — the difference
    /// between a dead end and a next step.
    public static func composedMessage(for error: Error) -> String {
        let top = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cause = deepestDescription(of: error), cause != top else {
            return top
        }
        return "\(top) \(cause)"
    }
}
