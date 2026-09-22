import SwiftUI

struct SettingsView: View {
    var body: some View {
        List {
            Section("Privacy") {
                Label("No analytics or advertising", systemImage: "hand.raised")
                Text("Health samples remain on this device in this build. Future synchronization will use the HTTPS destination you configure.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("VitalRoute requests read access only. It does not write to Apple Health.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Sync behavior") {
                Label("Manual sync first", systemImage: "arrow.triangle.2.circlepath")
                Text("Background delivery, retries, and deletion handling are planned for a later phase.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Build", value: buildNumber)
                Text("VitalRoute is a health-data synchronization utility. It does not provide medical advice.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}
