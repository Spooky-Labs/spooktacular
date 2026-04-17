# Accessibility Conformance Report (VPAT scaffold)

**Status:** Pre-audit scaffold. Third-party WCAG 2.1 AA audit has not yet been performed.
**Owner:** accessibility@spooktacular.app (interim: security@spooktacular.app).
**Reference format:** VPAT 2.4 Rev 508 — <https://www.section508.gov/sell/vpat/>.

This document is a truthful pre-report rather than a completed VPAT. Fortune-20 procurement reviewers use it to understand what accessibility work has been done, what remains, and when to expect a formal report. A completed VPAT will replace this scaffold once the third-party audit closes.

## 1. Product identification

- **Product:** Spooktacular — macOS application and `spook` command-line interface.
- **Version:** pre-1.0.
- **Target standards:** WCAG 2.1 AA, Section 508 (36 CFR Part 1194), EN 301 549.

## 2. Applicable parts

- **Chapter 4 (Hardware):** N/A — software product.
- **Chapter 5 (Software):** applies to the macOS GUI (`Spooktacular.app`).
- **Chapter 6 (Support documentation and services):** applies to published documentation.
- **Chapter 7 (Electronic content):** applies to documentation and any bundled web resources.

Chapter 5 is the primary evaluation target.

## 3. Formal audit status

- **Third-party audit:** **not yet performed**. Target engagement Q2 2026, target report publication Q3 2026.
- **Firm:** TBD (RFP in progress alongside the SOC 2 firm selection — see [`AUDIT_STATUS.md`](AUDIT_STATUS.md)).
- **Scope of planned audit:** the macOS GUI (end-to-end user flows covering VM creation, runner configuration, break-glass ticket issuance, role management).
- **Out of scope:** the `spook` CLI. Command-line interfaces are outside Section 508 Chapter 5 applicability for screen-reader conformance; the CLI is evaluated instead against plain-text output conventions (VPAT §502.4 non-software analogue).

## 4. In-house accessibility features implemented

The GUI ships with the following controls, authored in-house against Apple's accessibility APIs. This is an honest inventory of what has been coded, not a claim of WCAG conformance.

| Feature | Implementation | Known gap |
|---------|----------------|-----------|
| Accessibility labels on every interactive control | `.accessibilityLabel(_:)` modifiers on SwiftUI views | Dynamic labels that depend on VM state are being wired — tracked in the accessibility work-stream |
| Accessibility hints | `.accessibilityHint(_:)` on flows with non-obvious outcomes (e.g., destructive VM-delete) | Hint coverage is not yet exhaustive for the runner-pool view |
| Accessibility identifiers | `.accessibilityIdentifier(_:)` for UI tests and assistive-tech targeting | Identifiers exist but are not guaranteed stable across releases yet |
| Accessibility announcements | `AccessibilityNotification.Announcement` for async state changes | Announcement rate-limiting under review to avoid VoiceOver spam during pool reconciliation |
| Reduce-motion support | `@Environment(\.accessibilityReduceMotion)` gating transitions | Comprehensive — every animation checks this |
| Dynamic Type | `Font.TextStyle` used consistently | Dense panels (audit-log viewer) overflow at `.accessibility3` and above |
| High-contrast colors | System palette via `Color(.label)`, `Color(.systemBackground)` | No custom color tokens; relies on macOS system appearance |
| Keyboard navigation | Native SwiftUI focus behavior | Focus-trapping in modals has not been audited |

## 5. Known gaps (honest inventory)

These gaps will be closed or explicitly documented before a formal VPAT is issued:

- **VoiceOver label drift on dynamic state:** some labels say "Delete VM" instead of "Delete VM named `<name>`". Work in progress.
- **Dense audit-log view:** does not reflow at the largest Dynamic Type sizes. Planned fix: switch to a table view that supports accessibility content sizing.
- **Color-contrast ratios:** not yet measured under custom macOS appearance settings (Increase Contrast on, Reduce Transparency on). The system-palette dependency should satisfy WCAG 1.4.3 AA but needs verification.
- **Screen-reader order** in multi-column views has not been audited end-to-end.
- **Captioning / transcripts:** no audio content is shipped, so WCAG 1.2 does not apply. Documentation screenshots lack image-description alt-text — tracked.

## 6. Command-line interface accessibility

`spook` is a POSIX-style CLI. Screen-reader support is provided by the terminal emulator, not by `spook` itself. In-house practices that support accessibility:

- Plain-text output by default. Structured output is `--json` opt-in.
- No Unicode decorations in default output (no box-drawing, no emoji, no ANSI colors unless `stdout` is a TTY and `NO_COLOR` is unset, per <https://no-color.org/>).
- Error messages are concise, single-line, and machine-parseable.
- Long help text wraps at 80 columns to match standard terminal widths.
- `--help` output is exhaustive — every flag is documented.

WCAG 2.1 does not directly apply to CLIs. Section 508 §502.4 (platform accessibility services) is the closest analogue; `spook` conforms by not interfering with the terminal's own accessibility pathway.

## 7. Roadmap

- **Q2 2026** — complete dynamic VoiceOver label wiring; internal WCAG 2.1 AA self-audit using Accessibility Inspector.
- **Q2 2026** — engage third-party firm for external audit.
- **Q3 2026** — formal VPAT 2.4 Rev 508 issued, replacing this scaffold.
- **Q4 2026** — begin Section 508 Voluntary Product Accessibility Template sales distribution.

## 8. Feedback

Accessibility issues are tracked as security-equivalent — file via GitHub issues with label `accessibility`, or email accessibility@spooktacular.app. High-severity accessibility defects (total blocker for a class of users) follow the Critical SLA in [`PATCH_POLICY.md`](PATCH_POLICY.md).

## References

- Section 508 / VPAT — <https://www.section508.gov/sell/vpat/>
- WCAG 2.1 — <https://www.w3.org/TR/WCAG21/>
- EN 301 549 — <https://www.etsi.org/deliver/etsi_en/301500_301599/301549/>
- Apple accessibility programming guide — <https://developer.apple.com/documentation/accessibility>
