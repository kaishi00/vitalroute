import SwiftUI

struct SettingsView: View {
    @Environment(AutomaticSyncEngine.self) private var autoSyncEngine
    @Environment(VitalRouteModel.self) private var model
    @Environment(DestinationConfigurationStore.self) private var destinationStore
    @Environment(DestinationCredentialStore.self) private var credentialStore
    @Environment(ExportSelectionStore.self) private var selectionStore
    @State private var isTogglingAutomaticSync = false

    var body: some View {
        List {
            Section("Privacy") {
                Label("No analytics or advertising", systemImage: "hand.raised")
                Text("Sync sends only the categories you enable, only to the destination you configure — manually when you tap Sync Now, automatically only if you turn automatic sync on.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("VitalRoute requests read access only. It does not write to Apple Health.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section {
                automaticSyncToggle

                if autoSyncEngine.isEnabled || autoSyncEngine.lastStatusMessage != nil {
                    automaticSyncStatus
                }
            } header: {
                Text("Automatic sync")
            } footer: {
                Text("When on, VitalRoute watches the categories you enabled in Health Data and delivers additions and deletions to your destination, resuming after interruptions. iOS decides when background work actually runs: delivery is throttled, never guaranteed to be immediate, and stops until the next launch if you force-quit the app. Opening the app catches up right away.")
            }

            Section("Sync behavior") {
                Label("Manual sync", systemImage: "arrow.triangle.2.circlepath")
                Text("Sync Now reads the last \(SyncLimits.windowDays) days for the selected categories and uploads it in batches over HTTPS. It works with or without automatic sync.")
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

    private var automaticSyncToggle: some View {
        HStack {
            Toggle(isOn: Binding(
                get: { autoSyncEngine.isEnabled },
                set: { newValue in toggleAutomaticSync(newValue) }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Automatic sync")
                    Text(modeDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(isTogglingAutomaticSync || !prerequisitesSatisfied)
        }
    }

    @ViewBuilder
    private var automaticSyncStatus: some View {
        LabeledContent("State", value: modeDescription)
        if autoSyncEngine.pendingCount > 0 {
            LabeledContent("Pending changes", value: "\(autoSyncEngine.pendingCount)")
        }
        if let lastDelivery = autoSyncEngine.lastDeliveryAt {
            LabeledContent(
                "Last delivery",
                value: lastDelivery.formatted(date: .abbreviated, time: .shortened)
            )
        }
        if let lastCheck = autoSyncEngine.lastCheckAt {
            LabeledContent(
                "Last check",
                value: lastCheck.formatted(date: .abbreviated, time: .shortened)
            )
        }
        if let nextRetry = autoSyncEngine.nextRetryAt {
            LabeledContent(
                "Next retry",
                value: nextRetry.formatted(date: .abbreviated, time: .shortened)
            )
        }
        if let message = autoSyncEngine.lastStatusMessage {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modeDescription: String {
        switch autoSyncEngine.mode {
        case .disabled:
            return "Off"
        case .active:
            return autoSyncEngine.isRunning ? "On · working…" : "On"
        case .paused:
            return "Paused"
        }
    }

    private var prerequisitesSatisfied: Bool {
        model.isHealthAvailable
            && destinationStore.isConfigured
            && credentialStore.hasCredential
            && selectionStore.hasSelection
    }

    private func toggleAutomaticSync(_ newValue: Bool) {
        guard !isTogglingAutomaticSync else { return }
        isTogglingAutomaticSync = true
        Task {
            defer { isTogglingAutomaticSync = false }
            if newValue {
                _ = await autoSyncEngine.enable(
                    destination: destinationStore.savedEndpoint,
                    token: credentialStore.loadedToken,
                    metrics: selectionStore.selectedMetrics
                )
            } else {
                autoSyncEngine.disable()
            }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}
