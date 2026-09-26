import SwiftUI

struct HealthDataView: View {
    @Environment(VitalRouteModel.self) private var model
    @Environment(ExportSelectionStore.self) private var selectionStore

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Read-only categories")
                        .font(.headline)
                    Text("Enable the categories you want to export. VitalRoute asks Apple Health for read access only to the categories you enable here — never write access. iOS does not tell apps whether read access was granted; only records returned by a query can be shown.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button {
                        Task {
                            await model.requestAccessAndLoadRecentData(
                                metrics: selectionStore.selectedMetrics
                            )
                        }
                    } label: {
                        HStack {
                            if model.isLoadingHealthData {
                                ProgressView()
                            }
                            Text(accessButtonTitle)
                        }
                    }
                    .disabled(!model.isHealthAvailable || model.isLoadingHealthData || !selectionStore.hasSelection)
                    .padding(.top, 4)
                    if !selectionStore.hasSelection {
                        Text("Enable at least one category to review Apple Health access.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            Section {
                ForEach(MetricCatalog.selectableMetrics.map(\.metric)) { metric in
                    metricRow(for: metric)
                }
            } header: {
                Text("Export selection")
            } footer: {
                Text("Toggles choose which categories are included when you sync — they are separate from Apple Health authorization. The preview below shows up to 20 recent samples per enabled category; syncing sends every sample in the configured history window, not just the preview.")
            }

            if let error = model.healthDataError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Health Data")
        .navigationBarTitleDisplayMode(.large)
    }

    private var accessButtonTitle: String {
        if !selectionStore.hasSelection {
            return "Select categories first"
        }
        return model.authorizationRequestCompleted ? "Refresh recent data" : "Review Apple Health access"
    }

    private func emptyRowDescription(for metric: HealthMetric) -> String {
        if !selectionStore.selectedMetrics.contains(metric) {
            return "Not selected for export"
        }
        if model.hasSuccessfulHealthQuery {
            return "No samples returned"
        }
        if model.isLoadingHealthData {
            return "Loading recent data…"
        }
        return model.authorizationRequestCompleted ? "Query did not complete" : metric.shortDescription
    }

    private func metricRow(for metric: HealthMetric) -> some View {
        let records = model.records(for: metric)
        let isSelected = selectionStore.selectedMetrics.contains(metric)
        let newestRecord = records.first

        return Toggle(isOn: Binding(
            get: { isSelected },
            set: { selectionStore.setMetric(metric, selected: $0) }
        )) {
            HStack(spacing: 14) {
                Image(systemName: metric.symbolName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.teal)
                    .frame(width: 40, height: 40)
                    .background(.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(metric.displayName)
                        .font(.body.weight(.medium))
                    Text(newestRecord.map { "Latest: " + $0.displayValue } ?? emptyRowDescription(for: metric))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Text("\(records.count)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(records.count) samples")
                }
            }
            .padding(.vertical, 3)
            .accessibilityElement(children: .combine)
        }
        .toggleStyle(.switch)
        .accessibilityLabel("Include \(metric.displayName) in export")
    }
}
