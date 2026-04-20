import ArgumentParser
import Foundation
import SpooktacularKit

extension Spooktacular {

    /// Prints an audit-friendly inventory of the security
    /// controls shipped in this Spooktacular release — one line
    /// per control with the file + line the reviewer can walk
    /// directly to.
    ///
    /// Designed for the Fortune-20 review loop: a reviewer pastes
    /// the output into their ticketing system as the evidence
    /// block for each control they needed to verify. The `--json`
    /// flag yields structured output for automated compliance
    /// tooling (SIEM ingestion, GRC platform imports).
    ///
    /// Every entry is a compile-time reference, not a runtime
    /// check — running `spook doctor --strict` covers the
    /// runtime-verification side. This command is the
    /// "where is this implemented" complement.
    struct SecurityControls: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "security-controls",
            abstract: "Print an inventory of shipped security controls with code references.",
            discussion: """
                Each row: control name, standard citation (OWASP / \
                NIST / ASVS), implementation path:line, and the \
                test suite that pins the contract.

                EXAMPLES:
                  spook security-controls
                  spook security-controls --json | jq
                """
        )

        @Flag(help: "Emit structured JSON for pipeline tooling.")
        var json: Bool = false

        func run() async throws {
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(SecurityControlInventory.all)
                print(String(data: data, encoding: .utf8) ?? "[]")
                return
            }

            print(Style.bold("Spooktacular Security Controls"))
            print("==============================")
            print()

            var byCategory: [String: [SecurityControl]] = [:]
            for control in SecurityControlInventory.all {
                byCategory[control.category, default: []].append(control)
            }

            for category in byCategory.keys.sorted() {
                Style.header(category)
                for control in byCategory[category]! {
                    print(Style.bold("  \(control.name)"))
                    print(Style.dim("    Standard:      ") + control.standard)
                    print(Style.dim("    Implementation: ") + control.implementation)
                    if let test = control.test {
                        print(Style.dim("    Test:          ") + test)
                    }
                    if let notes = control.notes {
                        print(Style.dim("    Notes:         ") + notes)
                    }
                    print()
                }
            }

            print(Style.dim("\(SecurityControlInventory.all.count) controls documented. For runtime verification, run `spook doctor --strict`."))
        }
    }
}

// MARK: - Inventory

/// A single security control's inventory entry.
///
/// Kept in a pure value type — and in a library target, not the
