import SwiftUI

struct SettingsView: View {
    @Environment(AutomaticSyncEngine.self) private var autoSyncEngine
    @Environment(BackfillPreferenceStore.self) private var backfillStore
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
                Text("Sync Now reads the configured history (currently \(backfillStore.depth.label.lowercased())) for the selected categories and uploads it in batches over HTTPS. It works with or without automatic sync.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("History to sync", selection: Binding(
                    get: { backfillStore.depth },
                    set: { backfillStore.set($0) }
                )) {
                    ForEach(BackfillDepth.allCases) { depth in
                        Text(depth.label).tag(depth)
                    }
                }
            } header: {
                Text("History to sync")
            } footer: {
                Text(historyFooter)
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
            // Prerequisites gate *enabling* only. A user whose categories were
            // cleared, or whose API key was removed, must still be able to
            // turn automatic sync off.
            .disabled(isTogglingAutomaticSync || (!autoSyncEngine.isEnabled && !prerequisitesSatisfied))
        }
    }

    @ViewBuilder
    private var automaticSyncStatus: some View {
        LabeledContent("State", value: modeDescription)
        if autoSyncEngine.pendingCount > 0 {
            LabeledContent("Pending changes", value: "\(autoSyncEngine.pendingCount)")
            if autoSyncEngine.backfillPendingCount > 0 {
                LabeledContent(
                    "…of which history backfill",
                    value: "\(autoSyncEngine.backfillPendingCount)"
                )
            }
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
            // A request, not a promise: iOS decides when background work
            // actually runs.
            LabeledContent(
                "Next attempt (requested)",
                value: nextRetry.formatted(date: .abbreviated, time: .shortened)
            )
        }
        if let message = autoSyncEngine.lastStatusMessage {
            // Only a pause is an error state; the off notice and the
            // post-hoc notices read as information, not as a failure.
            Label(message, systemImage: statusSymbol)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusSymbol: String {
        if case .paused = autoSyncEngine.displayStatus {
            return "exclamationmark.circle"
        }
        return "info.circle"
    }

    private var historyFooter: String {
        if backfillStore.depth == .allRecords {
            return "Every record in Apple Health is included the first time a category syncs. The initial backfill can be very large; it runs in resumable chunks that continue across syncs until caught up."
        }
        return "How far back the first sync of a category reaches. From then on, every change is captured going forward regardless of this setting. Choosing a deeper history re-syncs a fresh window that reaches further back; a shallower choice never discards what was already captured."
    }

    private var modeDescription: String {
        switch autoSyncEngine.displayStatus {
        case .off:
            return "Off"
        case .idle:
            return "On · up to date"
        case .working:
            return "On · syncing"
        case .backfilling:
            return "On · catching up"
        case .deliveringBacklog:
            return "On · delivering backlog"
        case .waitingRetry:
            return "On · waiting for retry"
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
                await autoSyncEngine.disable()
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
