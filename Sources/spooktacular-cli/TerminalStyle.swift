import ArgumentParser
import Foundation
import SpooktacularKit

// MARK: - CLI Bundle Lookup

/// Returns the bundle URL for the given VM name, printing styled
/// error messages and throwing `ExitCode.failure` if the bundle
/// does not exist.
///
/// This wraps ``SpooktacularPaths/requireBundle(for:)`` with
/// CLI-friendly styled output.
///
/// - Parameter name: The VM name.
/// - Returns: The bundle URL.
/// - Throws: `ExitCode.failure` if the bundle does not exist.
func requireBundle(for name: String) throws -> URL {
    do {
        return try SpooktacularPaths.requireBundle(for: name)
    } catch {
        print(Style.error("✗ VM '\(name)' not found."))
        print(Style.dim("  Run 'spook list' to see available virtual machines."))
        throw ExitCode.failure
    }
}

// MARK: - CLI Exit Codes

/// Documented exit codes used across the spook CLI.
///
/// Every command's `--help` discussion references these values so
/// shell scripts can branch deterministically on failure mode.
///
/// ## Convention
///
/// | Code | Meaning |
/// |------|---------|
/// | 0    | Success |
/// | 1    | Network failure, bundle-exists, or general I/O |
/// | 2    | Insufficient disk space |
/// | 3    | Invalid input / validation failure |
/// | 4    | VM not found |
/// | 5    | Permission denied |
enum CLIExit {
    static let success: Int32 = 0
    static let generalFailure: Int32 = 1
    static let diskSpace: Int32 = 2
    static let validation: Int32 = 3
    static let notFound: Int32 = 4
    static let permission: Int32 = 5
}

// MARK: - JSON Output Helpers

/// Prints an `Encodable` payload as JSON to stdout.
///
/// Uses sorted keys and pretty-printing for deterministic diffs
/// in CI logs. On encoding failure, writes a structured error
/// document so consumers never receive a half-encoded payload.
///
/// All commands that expose `--json` route through this helper so
/// output is byte-identical regardless of command.
///
/// - Parameter value: The `Encodable` payload.
func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    do {
        let data = try encoder.encode(value)
        if let string = String(data: data, encoding: .utf8) {
            print(string)
        }
    } catch {
        // Never leak a half-encoded payload. Emit a structured
        // error document so shell pipelines can still `jq .error`.
        let fallback = #"{"error":"encoding-failed","detail":"\#(error.localizedDescription)"}"#
        print(fallback)
    }
}

/// Prints a structured error document to stdout for `--json` mode.
///
/// - Parameters:
///   - code: A stable, machine-readable error code.
///   - message: A human-readable explanation.
///   - hint: Optional recovery suggestion.
func printJSONError(code: String, message: String, hint: String? = nil) {
    struct ErrorDocument: Encodable {
        let error: String
        let message: String
        let hint: String?
    }
    printJSON(ErrorDocument(error: code, message: message, hint: hint))
}

// MARK: - Operation Duration

/// Formats an elapsed time in seconds for human-readable CLI output.
///
/// Values under 60s are shown as `"XX.Xs"`, longer operations
/// fall back to `"XmXXs"`.
func formatElapsed(_ seconds: TimeInterval) -> String {
    if seconds < 60 {
        return String(format: "%.1fs", seconds)
    }
    let minutes = Int(seconds) / 60
    let remaining = Int(seconds) % 60
    return "\(minutes)m\(remaining)s"
}

/// Styled terminal output with ANSI color codes.
///
/// Respects the `NO_COLOR` environment variable and checks
/// `isatty()` to avoid emitting escape codes when piped.
/// All CLI output should use these helpers for consistency.
///
/// ## Convention
///
/// | Color | Meaning |
/// |-------|---------|
/// | Green | Success, healthy, running |
/// | Red | Error, failure, critical |
/// | Yellow | Warning, degraded |
/// | Cyan | Info, progress, secondary data |
/// | Dim | Tertiary detail, paths, IDs |
/// | Bold | Headers, emphasis, names |
enum Style {

    // MARK: - Color Detection

    /// Whether the terminal supports ANSI color output.
    static let isEnabled: Bool = {
        if ProcessInfo.processInfo.environment["NO_COLOR"] != nil {
            return false
        }
        if ProcessInfo.processInfo.environment["CLICOLOR_FORCE"] != nil {
            return true
        }
        return isatty(fileno(stdout)) == 1
    }()

    // MARK: - ANSI Codes

    private static let escapePrefix = "\u{001B}["
    private static let reset = "\u{001B}[0m"

    // MARK: - Semantic Styles

    /// Green bold — success, completion.
    static func success(_ text: String) -> String {
        styled(text, codes: "1;32")
    }

    /// Red bold — error, failure.
    static func error(_ text: String) -> String {
        styled(text, codes: "1;31")
    }

    /// Yellow — warning.
    static func warning(_ text: String) -> String {
        styled(text, codes: "33")
    }

    /// Cyan — informational, progress.
    static func info(_ text: String) -> String {
        styled(text, codes: "36")
    }

    /// Bold — emphasis, names, headers.
    static func bold(_ text: String) -> String {
        styled(text, codes: "1")
    }

    /// Dim — secondary info, paths, IDs.
    static func dim(_ text: String) -> String {
        styled(text, codes: "2")
    }

    /// Green — healthy, running, enabled.
    static func green(_ text: String) -> String {
        styled(text, codes: "32")
    }

    /// Yellow — paused, warning.
    static func yellow(_ text: String) -> String {
        styled(text, codes: "33")
    }

    // MARK: - Formatting Helpers

    /// Prints a section header.
    static func header(_ text: String) {
        print()
        print(bold(text))
        print(dim(String(repeating: "─", count: min(text.count + 4, 60))))
    }

    /// Prints a key-value pair with aligned columns.
    static func field(_ label: String, _ value: String, labelWidth: Int = 16) {
        let padded = label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
        print("  \(dim(padded)) \(value)")
    }

    /// Prints a table with headers and rows.
    static func table(headers: [String], rows: [[String]]) {
        guard !headers.isEmpty else { return }

        // Calculate column widths.
        var widths = headers.map(\.count)
        for row in rows {
            for (i, cell) in row.enumerated() where i < widths.count {
                widths[i] = max(widths[i], cell.count)
            }
        }

        // Header row.
        let headerLine = zip(headers, widths).map { header, width in
            header.padding(toLength: width, withPad: " ", startingAt: 0)
        }.joined(separator: "  ")
        print(bold(headerLine))

        let separator = widths.map { String(repeating: "─", count: $0) }
            .joined(separator: "  ")
        print(dim(separator))

        // Data rows.
        for row in rows {
            let line = zip(row, widths).map { cell, width in
                cell.padding(toLength: width, withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
            print(line)
        }
    }

    // MARK: - Network Mode Labels

    /// Styled label for a network mode, used across CLI commands.
    static func networkLabel(_ mode: NetworkMode) -> String {
        switch mode {
        case .nat: dim("nat")
        case .bridged(let interface): info("bridged:\(interface)")
        case .isolated: yellow("isolated")
        }
    }

    // MARK: - Private

    private static func styled(_ text: String, codes: String) -> String {
        guard isEnabled else { return text }
        return "\(escapePrefix)\(codes)m\(text)\(reset)"
    }
}
