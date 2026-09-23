import Foundation
import Observation

@MainActor
@Observable
final class VitalRouteModel {
    @ObservationIgnored private let healthData: any HealthDataProviding

    private(set) var authorizationRequestCompleted = false
    private(set) var hasSuccessfulHealthQuery = false
    private(set) var recentRecords: [HealthRecord] = []
    private(set) var isLoadingHealthData = false
    private(set) var healthDataError: String?

    init(healthData: any HealthDataProviding) {
        self.healthData = healthData
    }

    var isHealthAvailable: Bool {
        healthData.isAvailable
    }

    /// Reviews Apple Health access and refreshes the dashboard preview. Only
    /// the selected categories are requested and queried — selection drives
    /// authorization scope, and refreshing never uploads anything.
    func requestAccessAndLoadRecentData(metrics: Set<HealthMetric>) async {
        guard isHealthAvailable else {
            healthDataError = "Apple Health is not available on this device."
            return
        }
        guard !metrics.isEmpty else {
            healthDataError = "Select at least one category in Health Data, then review access."
            return
        }
        guard !isLoadingHealthData else {
            return
        }

        isLoadingHealthData = true
        healthDataError = nil
        hasSuccessfulHealthQuery = false
        recentRecords.removeAll(keepingCapacity: true)
        defer { isLoadingHealthData = false }

        do {
            try await healthData.requestReadAuthorization(for: metrics)
            authorizationRequestCompleted = true
            let startDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            let records = try await healthData.queryRecentRecords(
                since: startDate,
                metrics: metrics,
                perMetricLimit: 20
            )
            recentRecords = records
            hasSuccessfulHealthQuery = true
        } catch {
            healthDataError = error.localizedDescription
        }
    }

    func records(for metric: HealthMetric) -> [HealthRecord] {
        recentRecords.filter { $0.metric == metric }
    }
}
