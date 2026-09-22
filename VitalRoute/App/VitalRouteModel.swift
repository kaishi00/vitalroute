import Foundation
import Observation

@MainActor
@Observable
final class VitalRouteModel {
    @ObservationIgnored private let healthData: any HealthDataProviding

    private(set) var authorizationRequestCompleted = false
    private(set) var recentRecords: [HealthRecord] = []
    private(set) var isLoadingHealthData = false
    private(set) var healthDataError: String?
    private(set) var lastReadAt: Date?

    init(healthData: any HealthDataProviding) {
        self.healthData = healthData
    }

    var isHealthAvailable: Bool {
        healthData.isAvailable
    }

    func requestAccessAndLoadRecentData() async {
        guard isHealthAvailable else {
            healthDataError = "Apple Health is not available on this device."
            return
        }
        guard !isLoadingHealthData else {
            return
        }

        isLoadingHealthData = true
        healthDataError = nil
        defer { isLoadingHealthData = false }

        do {
            try await healthData.requestReadAuthorization()
            authorizationRequestCompleted = true
            let startDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            recentRecords = try await healthData.queryRecentRecords(since: startDate, perMetricLimit: 20)
            lastReadAt = Date()
        } catch {
            healthDataError = error.localizedDescription
        }
    }

    func records(for metric: HealthMetric) -> [HealthRecord] {
        recentRecords.filter { $0.metric == metric }
    }
}
