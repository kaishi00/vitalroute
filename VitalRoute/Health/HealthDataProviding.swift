import Foundation

@MainActor
protocol HealthDataProviding {
    var isAvailable: Bool { get }
    func requestReadAuthorization() async throws
    func queryRecentRecords(since startDate: Date, perMetricLimit: Int) async throws -> [HealthRecord]
}
