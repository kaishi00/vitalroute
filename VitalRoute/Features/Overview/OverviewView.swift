import SwiftUI

struct OverviewView: View {
    @Environment(VitalRouteModel.self) private var model
    @Environment(DestinationConfigurationStore.self) private var destinationStore

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

            Text("VitalRoute requests read-only access to the categories listed in Health Data. Apple keeps read permission private, so an empty result can mean there is no recent data or access was not granted.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await model.requestAccessAndLoadRecentData() }
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
            .disabled(!model.isHealthAvailable || model.isLoadingHealthData)
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
        VStack(alignment: .leading, spacing: 10) {
            Button {} label: {
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            .disabled(true)

            Text("Secure delivery is not available yet. No health data leaves this device in this build.")
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
                Text("7 days")
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
                Text("No recent samples were returned. Apple Health does not reveal whether read access was declined or no data is available.")
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
        return destinationStore.isConfigured ? "Configured · HTTPS" : "Not configured"
    }

    private var destinationDetailText: String {
        guard destinationStore.isLoaded else {
            return "The saved destination will appear here."
        }
        return destinationStore.isConfigured ? "Saved securely in Keychain" : "Add an endpoint you control."
    }
}
