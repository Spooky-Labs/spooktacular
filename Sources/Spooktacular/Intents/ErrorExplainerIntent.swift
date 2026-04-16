import Foundation
import SwiftUI

/// WWDC 2025 headline: **on-device error explanation via
/// Foundation Models**.
///
/// When a VM fails to start or throws a cryptic Virtualization-
/// framework error, the user sees a glass sheet with an "Explain
/// this error" button. Tapping it streams a natural-language
/// explanation from Apple's on-device `SystemLanguageModel` — no
/// network call, no secrets leave the host, no API key required.
///
/// The feature is availability-gated on both the Foundation
/// Models framework (which ships in macOS 26) and device
/// capability (Apple Silicon with the Apple Intelligence model
/// installed). On any other configuration the view degrades to a
/// static explanation + a copy-error-to-clipboard button.

#if canImport(FoundationModels)
import FoundationModels

/// Streams an explanation of a VM error via the on-device LLM.
///
/// `ErrorExplainer.explain(_:context:)` returns an
/// `AsyncThrowingStream` of cumulative text snapshots — SwiftUI
/// views bind to it with `.task` and replace their text buffer
/// with the latest snapshot as it arrives, matching Siri's
/// streaming feel.
@available(macOS 26.0, *)
@MainActor
enum ErrorExplainer {

    /// The prompt template. Keeps explanations short, actionable,
    /// and focused on "what do I do next" rather than reciting
    /// the error verbatim.
    private static let systemPrompt = """
    You are a Mac developer expert explaining an error from \
    Spooktacular, a macOS virtualization tool that uses Apple's \
    Virtualization.framework. Respond in two short paragraphs: \
    first plainly explain what the error means, then give a \
    single concrete next step the user can try. Keep it under \
    80 words. Don't recite the full error text.
    """

    /// Whether the on-device model is available on this host.
    /// Views should fall back gracefully when this returns false.
    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// Streams an explanation for the given error as cumulative
    /// text snapshots (each snapshot contains the full explanation
    /// so far).
    ///
    /// - Parameters:
    ///   - error: The user-facing error text (e.g.
    ///     `error.localizedDescription`).
    ///   - context: Optional additional context — recent log
    ///     lines, the VM's spec, anything that helps.
    /// - Returns: An `AsyncThrowingStream` of cumulative text.
    static func explain(
        _ error: String,
        context: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let session = LanguageModelSession(
                    model: SystemLanguageModel.default,
                    instructions: systemPrompt
                )
                let prompt: String
                if let context {
                    prompt = "Error:\n\(error)\n\nContext:\n\(context)"
                } else {
                    prompt = "Error:\n\(error)"
                }
                do {
                    let stream = session.streamResponse(to: prompt)
                    for try await snapshot in stream {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
#endif

// MARK: - View

/// Glass sheet surfacing an on-device explanation of a VM error.
///
/// Bind `isPresented` from the error alert's "Explain" button.
struct ErrorExplainerSheet: View {

    let errorMessage: String
    let context: String?

    @Environment(\.dismiss) private var dismiss
    @State private var explanation: String = ""
    @State private var failed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Explain this error", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Original error")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(errorMessage)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)

                    Divider()

                    Text("Explanation")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    explanationBody
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .glassCard(cornerRadius: 12)
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 340)
        .task(id: errorMessage) {
            await streamExplanation()
        }
    }

    @ViewBuilder
    private var explanationBody: some View {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if ErrorExplainer.isAvailable {
                if explanation.isEmpty && !failed {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Asking the on-device model…")
                            .foregroundStyle(.secondary)
                    }
                } else if failed {
                    staticFallback(
                        note: "The on-device model couldn't answer. Here's a generic tip instead."
                    )
                } else {
                    Text(explanation)
                        .textSelection(.enabled)
                }
            } else {
                staticFallback(note: "Apple Intelligence isn't set up on this Mac.")
            }
        } else {
            staticFallback(note: "On-device explanations require macOS 26.")
        }
        #else
        staticFallback(note: "Built without Foundation Models support.")
        #endif
    }

    @ViewBuilder
    private func staticFallback(note: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Check the VM's log, verify the IPSW matches the host's Apple Silicon generation, and ensure Spooktacular has Virtualization entitlements.")
                .font(.callout)
        }
    }

    private func streamExplanation() async {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return }
        guard ErrorExplainer.isAvailable else { return }
        do {
            // Each snapshot is the full explanation so far — replace,
            // don't append.
            for try await snapshot in ErrorExplainer.explain(errorMessage, context: context) {
                explanation = snapshot
            }
        } catch {
            failed = true
        }
        #endif
    }
}
