import Foundation

/// The result of a complete export query: every record in the window up to
/// bounded per-category page caps. `truncatedMetrics` names categories whose
/// caps were hit — a truncated export must never be reported as complete.
struct HealthExportResult: Equatable {
    let records: [HealthRecord]
    let truncatedMetrics: Set<HealthMetric>

    var isTruncated: Bool {
        !truncatedMetrics.isEmpty
    }
}

@MainActor
protocol HealthDataProviding {
    var isAvailable: Bool { get }

    /// Requests read authorization for exactly the selected categories.
    func requestReadAuthorization(for metrics: Set<HealthMetric>) async throws

    /// Bounded preview query for the dashboard.
    func queryRecentRecords(
        since startDate: Date,
        metrics: Set<HealthMetric>,
        perMetricLimit: Int
    ) async throws -> [HealthRecord]

    /// Full export query for the sync window; pages through every matching
    /// record instead of stopping at a preview limit.
    func exportRecords(
        since startDate: Date,
        metrics: Set<HealthMetric>
    ) async throws -> HealthExportResult
}
