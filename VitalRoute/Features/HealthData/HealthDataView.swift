import SwiftUI

struct HealthDataView: View {
    @Environment(VitalRouteModel.self) private var model

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Read-only categories")
                        .font(.headline)
                    Text("VitalRoute asks Apple Health for access only to these seven categories. iOS does not tell apps whether read access was granted; only records returned by a query can be shown.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await model.requestAccessAndLoadRecentData() }
                    } label: {
                        HStack {
                            if model.isLoadingHealthData {
                                ProgressView()
                            }
                            Text(model.authorizationRequestCompleted ? "Refresh recent data" : "Review Apple Health access")
                        }
                    }
                    .disabled(!model.isHealthAvailable || model.isLoadingHealthData)
                    .padding(.top, 4)
                }
                .padding(.vertical, 6)
            }

            Section("Recent samples · last 7 days") {
                ForEach(HealthMetric.allCases) { metric in
                    metricRow(for: metric)
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
        .navigationTitle("Health Data")
        .navigationBarTitleDisplayMode(.large)
    }

    private func metricRow(for metric: HealthMetric) -> some View {
        let records = model.records(for: metric)
        let newestRecord = records.first

        return HStack(spacing: 14) {
            Image(systemName: metric.symbolName)
                .font(.body.weight(.semibold))
                .foregroundStyle(.teal)
                .frame(width: 40, height: 40)
                .background(.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 4) {
                Text(metric.displayName)
                    .font(.body.weight(.medium))
                Text(newestRecord.map { "Latest: " + $0.displayValue } ?? (model.authorizationRequestCompleted ? "No samples returned" : metric.shortDescription))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text("\(records.count)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(records.count) samples")
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}
