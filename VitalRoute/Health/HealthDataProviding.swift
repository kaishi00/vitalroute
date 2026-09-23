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

/// One page of incremental changes for a category. `anchorData` is the
/// serialized cursor to persist after the page's changes are durably
/// recorded; `isFull` marks a pagination boundary.
struct HealthChangePage: Equatable {
    let additions: [HealthRecord]
    let deletions: [DeletedRecord]
    let anchorData: Data?
    let isFull: Bool
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
    /// record instead of stopping at a preview limit. `through` pins the
    /// window end so an operation reads a consistent interval.
    func exportRecords(
        since startDate: Date,
        through endDate: Date,
        metrics: Set<HealthMetric>
    ) async throws -> HealthExportResult

    /// One incremental page of additions and deletions for a category since
    /// the given serialized anchor, restricted to samples starting at or
    /// after `windowStart`. The predicate is fixed per scope and must never
    /// move: anchors are only valid with the predicate that produced them.
    func changePage(
        for metric: HealthMetric,
        since anchorData: Data?,
        windowStart: Date,
        limit: Int
    ) async throws -> HealthChangePage

    /// Registers change observers for the categories; re-registering replaces
    /// the previous observer set, and a failed registration leaves none of
    /// its partial work behind.
    ///
    /// `handler` runs on a HealthKit queue whenever new data arrives. It
    /// receives an exactly-once completion for that notification, which the
    /// caller releases once the work the notification triggered is durable —
    /// not before, and never on network success alone. Notifications whose
    /// capture never finishes are released on the coordinator's deadline.
    func observeChanges(
        for metrics: Set<HealthMetric>,
        handler: @escaping @Sendable (ObserverCompletion) -> Void
    ) async throws

    /// Removes all observers registered by this service, including the
    /// background delivery they were armed with.
    func stopObservingChanges() async
}
