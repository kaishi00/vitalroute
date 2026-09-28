import SwiftUI

struct HealthDataView: View {
    @Environment(VitalRouteModel.self) private var model
    @Environment(ExportSelectionStore.self) private var selectionStore
    @State private var searchText = ""

    /// Familiar abbreviations map to the catalog IDs that describe them.
    /// Keeping these few discovery aliases here avoids per-metric UI logic.
    private static let searchAliases: [String: Set<String>] = [
        "hrv": ["heartRateVariability"],
        "bmi": ["bodyMassIndex"],
        "spo2": ["oxygenSaturation"],
        "bpm": ["heartRate", "restingHeartRate", "walkingHeartRateAverage", "heartRateRecoveryOneMinute"],
    ]

    private static func searchNormalized(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "₂", with: "2")
            .replacingOccurrences(of: "₀", with: "0")
    }

    /// Pure catalog filtering so the selector's search and grouping contract
    /// can be checked without constructing SwiftUI views.
    static func filteredDescriptors(query: String) -> [MetricDescriptor] {
        let descriptors = MetricCatalog.selectableMetrics
        let term = searchNormalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !term.isEmpty else { return descriptors }
        return descriptors.filter {
            let searchableText = searchNormalized("\($0.displayName) \($0.shortDescription) \($0.metric.rawValue)")
            return searchableText.localizedCaseInsensitiveContains(term)
                || searchAliases[term, default: []].contains($0.metric.rawValue)
        }
    }

    static func groupedDescriptors(query: String) -> [MetricDescriptor.Group: [MetricDescriptor]] {
        let filtered = filteredDescriptors(query: query)
        return Dictionary(grouping: filtered, by: \.group)
    }

    static func recordsForSelectedMetrics(
        _ records: [HealthRecord],
        selectedMetrics: Set<HealthMetric>
    ) -> [HealthRecord] {
        records.filter { selectedMetrics.contains($0.metric) }
    }

    private var visibleGroups: [MetricDescriptor.Group] {
        let groups = Self.groupedDescriptors(query: searchText)
        return MetricDescriptor.Group.allCases.filter { groups[$0]?.isEmpty == false }
    }

    private func metrics(in group: MetricDescriptor.Group) -> [MetricDescriptor] {
        Self.groupedDescriptors(query: searchText)[group] ?? []
    }

    static func accessibleMetricLabel(
        for metric: HealthMetric,
        latestRecord: HealthRecord?,
        sampleCount: Int,
        emptyDescription: String,
        isSelected: Bool
    ) -> String {
        let latest = latestRecord.map { "Latest: \($0.displayValue)." } ?? emptyDescription
        let count = isSelected && sampleCount > 0 ? " \(sampleCount) samples." : ""
        return "Include \(metric.displayName) in export. \(metric.shortDescription). \(latest)\(count)"
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Choose health metrics")
                        .font(.headline)
                    Text("Choose the health metrics you want to export. Browsing and selecting metrics does not request Apple Health access. When you review access, VitalRoute requests read access only for selected metrics — never write access. iOS does not tell apps whether read access was granted; only records returned by a query can be shown.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Selected metrics are included in sync and remain separate from Apple Health authorization. The preview shows up to 20 recent samples per selected metric; syncing sends every sample in the configured history window, not just the preview.")
                        .font(.footnote)
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
                        Text("Select at least one metric to review Apple Health access.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            ForEach(visibleGroups, id: \.self) { group in
                Section {
                    ForEach(metrics(in: group).map(\.metric)) { metric in
                        metricRow(for: metric)
                    }
                } header: {
                    Text(group.rawValue.capitalized)
                }
            }

            if let error = model.healthDataError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "Search health metrics")
        .navigationTitle("Health Data")
        .navigationBarTitleDisplayMode(.large)
    }

    private var accessButtonTitle: String {
        if !selectionStore.hasSelection {
            return "Select metrics first"
        }
        return model.authorizationRequestCompleted ? "Refresh recent data" : "Review Apple Health access"
    }

    private func emptyRowDescription(for metric: HealthMetric) -> String {
        if !selectionStore.selectedMetrics.contains(metric) {
            return "Not selected for export"
        }
        if model.hasSuccessfulHealthQuery {
            return "No recent samples shown; refresh to check"
        }
        if model.isLoadingHealthData {
            return "Loading recent data…"
        }
        return model.authorizationRequestCompleted
            ? "Query did not complete"
            : "Review Apple Health access to check for samples"
    }

    private func metricRow(for metric: HealthMetric) -> some View {
        let isSelected = selectionStore.selectedMetrics.contains(metric)
        let records = isSelected ? model.records(for: metric) : []
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
                    Text(metric.shortDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                }
            }
            .padding(.vertical, 3)
            .accessibilityElement(children: .combine)
        }
        .toggleStyle(.switch)
        .accessibilityLabel(Self.accessibleMetricLabel(
            for: metric,
            latestRecord: newestRecord,
            sampleCount: records.count,
            emptyDescription: emptyRowDescription(for: metric),
            isSelected: isSelected
        ))
    }
}
