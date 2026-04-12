import Foundation
import SpooktacularKit

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

    private static let esc = "\u{001B}["
    private static let reset = "\(esc)0m"

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

    /// Red — stopped, disabled, error.
    static func red(_ text: String) -> String {
        styled(text, codes: "31")
    }

    /// Yellow — paused, warning.
    static func yellow(_ text: String) -> String {
        styled(text, codes: "33")
    }

    /// Blue — headers, sections.
    static func blue(_ text: String) -> String {
        styled(text, codes: "34")
    }

    /// Magenta — special, interactive.
    static func magenta(_ text: String) -> String {
        styled(text, codes: "35")
    }

    // MARK: - Symbols

    /// ✓ in green.
    static let checkmark = success("✓")

    /// ✗ in red.
    static let cross = error("✗")

    /// ⚠ in yellow.
    static let warn = warning("⚠")

    /// ● in green (running).
    static let dotRunning = green("●")

    /// ○ (stopped).
    static let dotStopped = dim("○")

    /// ◐ in yellow (paused).
    static let dotPaused = yellow("◐")

    /// ◌ in red (error).
    static let dotError = red("◌")

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

    /// Formats a progress bar.
    static func progressBar(
        fraction: Double,
        width: Int = 30,
        label: String = ""
    ) -> String {
        let filled = Int(fraction * Double(width))
        let empty = width - filled
        let bar = String(repeating: "█", count: filled)
            + String(repeating: "░", count: empty)
        let pct = String(format: "%3.0f%%", fraction * 100)

        if label.isEmpty {
            return "\(info(bar)) \(pct)"
        } else {
            return "\(label) \(info(bar)) \(pct)"
        }
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
        case .bridged(let iface): info("bridged:\(iface)")
        case .isolated: yellow("isolated")
        case .hostOnly: dim("host-only")
        }
    }

    /// Raw (unstyled) label for a network mode, for machine output.
    static func networkRaw(_ mode: NetworkMode) -> String {
        switch mode {
        case .nat: "nat"
        case .bridged(let iface): "bridged:\(iface)"
        case .isolated: "isolated"
        case .hostOnly: "host-only"
        }
    }

    // MARK: - Private

    private static func styled(_ text: String, codes: String) -> String {
        guard isEnabled else { return text }
        return "\(esc)\(codes)m\(text)\(reset)"
    }
}
