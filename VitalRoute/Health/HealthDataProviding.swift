import Foundation

/// One page of incremental changes for a category. `anchorData` is the
/// serialized cursor to persist after the page's changes are durably
/// recorded; `isFull` marks a pagination boundary.
struct HealthChangePage: Equatable {
    let additions: [HealthRecord]
    let deletions: [DeletedRecord]
    let anchorData: Data?
    let isFull: Bool
}

/// One page of additions-only export reading for a category. Like a change
/// page, `anchorData` is the cursor to persist only after the page has been
/// durably handled (delivered and acknowledged for manual exports), and
/// `isFull` marks that more pages follow.
struct HealthExportPage: Equatable {
    let records: [HealthRecord]
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

    /// One additions-only export page for a category since the given
    /// serialized anchor, restricted to samples starting at or after
    /// `windowStart`. The predicate is fixed per window start — the same
    /// anchor-validity rule as change pages — so a manual export resumes
    /// across runs by persisting the returned anchor. Deleted samples are
    /// deliberately not reported here; deletion propagation belongs to the
    /// change stream.
    func exportPage(
        for metric: HealthMetric,
        since anchorData: Data?,
        windowStart: Date,
        limit: Int
    ) async throws -> HealthExportPage

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
