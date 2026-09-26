import SwiftUI

struct OverviewView: View {
    @Environment(VitalRouteModel.self) private var model
    @Environment(DestinationConfigurationStore.self) private var destinationStore
    @Environment(DestinationCredentialStore.self) private var credentialStore
    @Environment(ExportSelectionStore.self) private var selectionStore
    @Environment(BackfillPreferenceStore.self) private var backfillStore
    @Environment(ManualSyncCoordinator.self) private var syncCoordinator
    @Environment(AutomaticSyncEngine.self) private var autoSyncEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                introduction
                accessCard
                destinationCard
                syncCard
                recentData
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Overview")
        .navigationBarTitleDisplayMode(.large)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PRIVATE HEALTH EXPORT")
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Text("Your health.\nYour route.")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Choose what VitalRoute can read, then route it to a destination you control.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 2)
    }

    private var accessCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: model.isHealthAvailable ? "heart.fill" : "heart.slash")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(model.isHealthAvailable ? .pink : .secondary)
                    .frame(width: 42, height: 42)
                    .background(.pink.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Apple Health")
                        .font(.headline)
                    Text(accessStatus)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(model.isHealthAvailable ? Color.teal : Color.gray)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
            }

            Text("VitalRoute requests read-only access to the categories you enable in Health Data. Apple keeps read permission private, so an empty result can mean there is no recent data or access was not granted.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task {
                    await model.requestAccessAndLoadRecentData(
                        metrics: selectionStore.selectedMetrics
                    )
                }
            } label: {
                HStack(spacing: 8) {
                    if model.isLoadingHealthData {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "heart.text.square")
                    }
                    Text(model.authorizationRequestCompleted ? "Refresh recent data" : "Review Apple Health access")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            .disabled(!model.isHealthAvailable || model.isLoadingHealthData || !selectionStore.hasSelection)
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var destinationCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.indigo)
                .frame(width: 42, height: 42)
                .background(.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Your destination")
                    .font(.headline)
                Text(destinationStatusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(destinationDetailText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Manual sync")
                    .font(.headline)
                Spacer()
                Text(backfillStore.depth.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
            }

            if syncCoordinator.isSyncing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(syncProgressText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Cancel sync", role: .destructive) {
                    syncCoordinator.cancelSync()
                }
                .frame(maxWidth: .infinity)
            } else {
                Button {
                    syncCoordinator.startSync(
                        endpoint: destinationStore.savedEndpoint,
                        token: credentialStore.loadedToken,
                        metrics: selectionStore.selectedMetrics
                    )
                } label: {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSync)

                Text(syncReadinessText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let outcomeText {
                Label(outcomeText, systemImage: outcomeImageName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let lastSync = syncCoordinator.lastSuccessfulSync {
                Text("Last successful sync: \(lastSync.finishedAt.formatted(date: .abbreviated, time: .shortened)) · \(lastSync.deliveredRecords) records acknowledged.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if autoSyncEngine.isEnabled {
                Text(automaticSyncSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Syncing sends every record found in the window for the selected categories — not just the preview above — in batches of \(SyncLimits.recordsPerUploadBatch). It only happens when you tap Sync Now; saving settings or opening the app never uploads data. Retrying is safe: the receiver keeps one copy of each record.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @ViewBuilder
    private var recentData: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent health data")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(backfillStore.depth.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
            }

            if let error = model.healthDataError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if model.isLoadingHealthData {
                Label("Loading recent health data…", systemImage: "hourglass")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if !model.authorizationRequestCompleted {
                Text("Review Apple Health access to load recent samples.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if !model.hasSuccessfulHealthQuery {
                Text("The latest health-data query did not complete.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if model.recentRecords.isEmpty {
                Text("No recent samples were returned for the selected categories. Apple Health does not reveal whether read access was declined or no data is available.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.recentRecords.prefix(3)) { record in
                    HStack(spacing: 12) {
                        Image(systemName: record.metric.symbolName)
                            .foregroundStyle(.teal)
                            .frame(width: 34, height: 34)
                            .background(.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.metric.displayName)
                                .font(.subheadline.weight(.medium))
                            Text(record.endDate.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(record.displayValue)
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    // MARK: Derived state

    private var automaticSyncSummary: String {
        let pending = autoSyncEngine.pendingCount > 0
            ? " · \(autoSyncEngine.pendingCount) pending"
            : ""
        switch autoSyncEngine.displayStatus {
        case .off:
            return ""
        case .idle:
            return "Automatic sync is on and up to date. VitalRoute is woken by Apple Health when new data arrives; iOS controls how soon background work runs."
        case .working:
            return "Automatic sync is delivering new records now."
        case .backfilling:
            return "Automatic sync is catching up on history — \(autoSyncEngine.backfillPendingCount) backfilled change(s) waiting to upload. New records are delivered ahead of them."
        case .deliveringBacklog:
            return "Automatic sync is uploading a backlog of \(autoSyncEngine.pendingCount) change(s) before it catches up on history. Delivery runs on every wake until the backlog is gone."
        case .waitingRetry:
            return "Automatic sync is on; \(autoSyncEngine.pendingCount) change(s) are waiting to upload and a retry has been requested. iOS decides when background work actually runs."
        case .paused(let reason):
            return "\(reason.userMessage)\(pending)"
        }
    }

    private var accessStatus: String {
        if !model.isHealthAvailable {
            return "Not available on this device"
        }
        return model.authorizationRequestCompleted ? "Access request completed" : "Ready to review access"
    }

    private var destinationStatusText: String {
        guard destinationStore.isLoaded else {
            return "Checking secure storage…"
        }
        if !destinationStore.isConfigured {
            return "Not configured"
        }
        // Pairing matters while a credential read is still failing: the
        // loaded key may describe the previous endpoint.
        let credentialPaired = credentialStore.credentialEndpoint == destinationStore.savedEndpoint
        return credentialStore.hasCredential && credentialPaired
            ? "Configured · HTTPS"
            : "Endpoint saved · API key missing"
    }

    private var destinationDetailText: String {
        guard destinationStore.isLoaded else {
            return "The saved destination will appear here."
        }
        if !destinationStore.isConfigured {
            return "Add an endpoint you control."
        }
        let credentialPaired = credentialStore.credentialEndpoint == destinationStore.savedEndpoint
        return credentialStore.hasCredential && credentialPaired
            ? destinationStore.savedEndpoint
            : "Add the API key for this destination to enable syncing."
    }

    private var canSync: Bool {
        model.isHealthAvailable
            && destinationStore.isConfigured
            && credentialStore.hasCredential
            // The credential must belong to the endpoint being synced — the
            // same invariant the connection test enforces.
            && credentialStore.credentialEndpoint == destinationStore.savedEndpoint
            && selectionStore.hasSelection
            && !syncCoordinator.isSyncing
    }

    private var syncReadinessText: String {
        if !model.isHealthAvailable {
            return "Apple Health is not available on this device, so there is nothing to sync."
        }
        if !destinationStore.isConfigured {
            return "Save an HTTPS destination and its API key to enable syncing."
        }
        if !credentialStore.hasCredential {
            return "Add the API key for this destination to enable syncing."
        }
        if !selectionStore.hasSelection {
            return "Enable at least one category in Health Data to sync."
        }
        return "Sends \(backfillStore.depth == .allRecords ? "all records" : "the \(backfillStore.depth.label.lowercased())") for \(selectionStore.selectedMetrics.count) selected categor\(selectionStore.selectedMetrics.count == 1 ? "y" : "ies") to your destination."
    }

    private var syncProgressText: String {
        switch syncCoordinator.phase {
        case .idle:
            return "Preparing…"
        case .authorizing:
            return "Confirming Apple Health access…"
        case .readingHealthData:
            return "Reading \(backfillStore.depth == .allRecords ? "all records" : "the \(backfillStore.depth.label.lowercased())") of selected categories…"
        case .uploading(let batch, let totalBatches):
            // totalBatches is 0 while pages stream (the total is unknown).
            let scope = totalBatches > 0 ? "batch \(batch) of \(totalBatches)" : "batch \(batch)"
            return "Uploading \(scope) · \(syncCoordinator.currentSummary.deliveredRecords) records acknowledged"
        }
    }

    private var outcomeText: String? {
        guard let outcome = syncCoordinator.lastOutcome, !syncCoordinator.isSyncing else {
            return nil
        }
        switch outcome.result {
        case .completed:
            if outcome.summary.recordsFound == 0 {
                return "Sync finished: no records were found in the window for the selected categories. Nothing was sent."
            }
            return "Sync finished: \(outcome.summary.deliveredRecords) records acknowledged (\(outcome.summary.acceptedRecords) new, \(outcome.summary.duplicateRecords) already present) — \(outcome.summary.breakdownText)."
        case .backfilling(let metrics):
            let names = metrics.map(\.displayName).sorted().joined(separator: ", ")
            return "History backfill in progress for \(names): \(outcome.summary.deliveredRecords) records acknowledged in this run and progress saved. Tap Sync Now to continue where it left off."
        case .failed(let message):
            let partial = outcome.summary.batchesDelivered > 0
                ? " \(outcome.summary.batchesDelivered) of \(outcome.summary.batchesPlanned) batches (\(outcome.summary.deliveredRecords) records) were acknowledged before the failure."
                : ""
            return "Sync failed: \(message)\(partial) Tap Sync Now to retry — the receiver keeps one copy of each record."
        case .cancelled:
            let partial = outcome.summary.deliveredRecords > 0
                ? " \(outcome.summary.deliveredRecords) records were acknowledged before cancelling."
                : ""
            return "Sync cancelled.\(partial)"
        }
    }

    private var outcomeImageName: String {
        switch syncCoordinator.lastOutcome?.result {
        case .completed:
            "checkmark.circle"
        case .cancelled:
            "xmark.circle"
        case .backfilling:
            "arrow.triangle.2.circlepath"
        case .failed:
            "exclamationmark.circle"
        case nil:
            "info.circle"
        }
    }
}
