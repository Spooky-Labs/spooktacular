import SwiftUI

/// The application settings view.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
        }
        .frame(width: 450, height: 200)
    }
}

struct GeneralSettingsView: View {

    private let storagePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".spooktacular")
        .path

    var body: some View {
        Form {
            Section("Data Directory") {
                LabeledContent("VM Storage") {
                    Text(storagePath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("VM storage directory")
                .accessibilityValue(storagePath)
            }
        }
        .formStyle(.grouped)
    }
}
