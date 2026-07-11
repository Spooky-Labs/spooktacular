import SwiftUI
import SpooktacularKit

/// Sheet for adding a VM image to the local library.
///
/// Supports two sources: a local IPSW file or an OCI image
/// reference (e.g., ghcr.io/spooktacular/macos:15.4).
struct AddImageSheet: View {

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Reduce Motion gate — the error-bar spring collapses to an
    /// instant state application when the user asks the system
    /// to reduce motion. (The header seals gate themselves.)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var sourceType: SourceType = .localFile
    @State private var name = ""
    @State private var filePath = ""
    @State private var ociReference = ""
    @State private var errorMessage: String?

    enum SourceType: String, CaseIterable {
        case localFile = "Local IPSW File"
        case ociImage = "OCI Image Reference"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Image")
                    .font(.headline)
                    // Display headings speak in SF Pro Rounded —
                    // the Apparition type voice.
                    .fontDesign(.rounded)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            VStack(alignment: .leading, spacing: 20) {
                // Source type picker
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        // Always sealed — the radio group can't
                        // hold an invalid value.
                        RitualSectionHeader(title: "Source", complete: true)
                            .font(.headline)
                            // Ritual section chips are chrome
                            // floating over the sheet ground —
                            // Liquid Glass capsule per the
                            // Apparition re-grade. Each chip is
                            // isolated (no adjacent glass), so no
                            // `GlassEffectContainer` — nothing to
                            // blend with, no at-rest merge risk.
                            // (Inlined: the fileprivate helper
                            // lives in CreateVMSheet.swift.)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .glassEffect(.regular, in: .capsule)

                        Picker("Source", selection: $sourceType) {
                            ForEach(SourceType.allCases, id: \.self) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(sourceType == .localFile
                        ? "Select a macOS IPSW restore image from your disk. " +
                          "Apple distributes these for each macOS version."
                        : "Enter an OCI image reference like " +
                          "ghcr.io/spooktacular/macos-xcode:15.4-16.2. " +
                          "The image will be pulled when used."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 200)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                // Name
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        // Seals (DrawOn) the moment a non-blank
                        // name exists.
                        RitualSectionHeader(
                            title: "Display Name",
                            complete: nameComplete
                        )
                        .font(.headline)
                        // Glass chip — chrome over the sheet
                        // ground, isolated, no container needed.
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)
                        TextField("macOS 15.4", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text("A human-readable name for this image. " +
                         "Shown in the sidebar and when creating VMs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 200)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                // Source-specific input
                if sourceType == .localFile {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 6) {
                            // Seals once a file path is present.
                            RitualSectionHeader(
                                title: "IPSW File",
                                complete: filePathComplete
                            )
                            .font(.headline)
                            // Glass chip — chrome over the sheet
                            // ground, isolated, no container needed.
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .glassEffect(.regular, in: .capsule)
                            HStack {
                                TextField("/path/to/file.ipsw", text: $filePath)
                                    .textFieldStyle(.roundedBorder)
                                Button("Browse…") { browseIPSW() }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text("The file will be copied into the image library at " +
                             "~/.spooktacular/images/.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 200)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 6) {
                            // Seals once a reference is present.
                            RitualSectionHeader(
                                title: "OCI Reference",
                                complete: ociReferenceComplete
                            )
                            .font(.headline)
                            // Glass chip — chrome over the sheet
                            // ground, isolated, no container needed.
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .glassEffect(.regular, in: .capsule)
                            TextField("ghcr.io/org/image:tag", text: $ociReference)
                                .textFieldStyle(.roundedBorder)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text("Supports any OCI-compliant registry: " +
                             "GHCR, Docker Hub, ECR, etc.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 200)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let error = errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Reading surface (validation prose), so
                        // material — not glass. Corners resolve
                        // concentric with the sheet's 26pt
                        // container (declared by
                        // `apparitionSheetGround()`) instead of
                        // hardcoding a small radius.
                        .background(
                            .regularMaterial,
                            in: ConcentricRectangle(
                                corners: .concentric(minimum: 10.0),
                                isUniform: true
                            )
                        )
                }
            }
            .padding(24)

            Divider()

            // Explicit interior spacing (10) LARGER than the
            // container spacing (8): per Apple's
            // GlassEffectContainer semantics, container spacing
            // >= interior stack spacing merges adjacent shapes at
            // rest — the fused-blob failure mode. (The Spacer
            // keeps this pair far apart anyway; the explicit
            // value makes the contract auditable, matching the
            // app's other sheet footers.)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 10) {
                    Button("Cancel") { dismiss() }
                        .glassButton()
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button {
                        addImage()
                    } label: {
                        Label("Add", systemImage: "plus")
                            // Hover delight: the plus bounces once
                            // on pointer entry (Reduce-Motion-gated
                            // inside the modifier).
                            .hoverSymbolBounce()
                    }
                    .glassProminentButton()
                    // The ONE wisp glassProminent on this
                    // surface — the accent marks the primary
                    // action and nothing else; the prominent
                    // style itself carries the wisp, so no
                    // manual `.tint` here.
                    .disabled(!isValid)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        // Ground the sheet in the Apparition palette (material +
        // faint night wash — no content-layer glass), and spring
        // the error label in/out on the `errorMessage` state
        // change.
        .apparitionSheetGround()
        .animation(reduceMotion ? nil : Apparition.spring, value: errorMessage)
        .frame(width: 600)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        (sourceType == .localFile
            ? !filePath.trimmingCharacters(in: .whitespaces).isEmpty
            : !ociReference.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    // MARK: - Ritual section validity
    //
    // Presentation-only mirrors of `isValid`'s per-field
    // requirements; each drives the completion seal in its
    // section header.

    /// The Display Name section seals once a non-blank name exists.
    private var nameComplete: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The IPSW File section seals once a path is present.
    private var filePathComplete: Bool {
        !filePath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The OCI Reference section seals once a reference is present.
    private var ociReferenceComplete: Bool {
        !ociReference.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func browseIPSW() {
        let panel = NSOpenPanel()
        panel.title = "Select IPSW File"
        panel.allowedContentTypes = [.data]
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            filePath = url.path
            if name.isEmpty {
                name = url.deletingPathExtension().lastPathComponent
            }
        }
    }

    private func addImage() {
        errorMessage = nil
        do {
            if sourceType == .localFile {
                let url = URL(filePath: filePath)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    errorMessage = "File not found at \(filePath)"
                    return
                }
                try appState.imageLibrary.addIPSW(at: url, name: name)
            } else {
                try appState.imageLibrary.addOCI(reference: ociReference, name: name)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
