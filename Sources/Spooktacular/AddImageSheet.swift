import SwiftUI
import SpooktacularKit

/// Sheet for adding a VM image to the local library.
///
/// Supports two sources: a local IPSW file or an OCI image
/// reference (e.g., ghcr.io/spooktacular/macos:15.4).
struct AddImageSheet: View {

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

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
                        Text("Source").font(.headline)

                        Picker("Source", selection: $sourceType) {
                            ForEach(SourceType.allCases, id: \.self) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
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
                        Text("Display Name").font(.headline).glassSectionHeader()
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
                            Text("IPSW File").font(.headline).glassSectionHeader()
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
                            Text("OCI Reference").font(.headline).glassSectionHeader()
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
                }
            }
            .padding(24)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") { addImage() }
                    .glassButton()
                    .disabled(!isValid)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 600)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        (sourceType == .localFile
            ? !filePath.trimmingCharacters(in: .whitespaces).isEmpty
            : !ociReference.trimmingCharacters(in: .whitespaces).isEmpty)
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
