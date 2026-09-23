import Foundation
import HealthKit

/// Lets exactly one thread claim a HealthKit callback; later invocations of
/// a long-running query handler are dropped instead of double-resuming a
/// continuation.
private final class ContinuationGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed {
            return false
        }
        claimed = true
        return true
    }
}

/// Holds the query reference so the callback can stop a long-running query
/// after its first invocation; the callback closure cannot capture the query
/// it is being constructed into.
private final class QueryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedQuery: HKAnchoredObjectQuery?

    var query: HKAnchoredObjectQuery? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedQuery
        }
        set {
            lock.lock()
            storedQuery = newValue
            lock.unlock()
        }
    }
}

@MainActor
final class HealthKitService: HealthDataProviding {
    private let healthStore = HKHealthStore()

    var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func requestReadAuthorization(for metrics: Set<HealthMetric>) async throws {
        guard isAvailable else {
            throw HealthKitServiceError.unavailable
        }
        guard !metrics.isEmpty else {
            // Requesting nothing would surface HealthKit's authorization
            // sheet for zero types; the caller is expected to have validated
            // a non-empty selection already.
            throw HealthKitServiceError.noMetricsRequested
        }

        let types = Set(metrics.compactMap { metric -> HKObjectType? in
            HealthKitRecordMapper.sampleType(for: metric)
        })

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.requestAuthorization(toShare: Set<HKSampleType>(), read: types) { granted, error in
                if let failure = HealthKitServiceError.authorizationError(granted: granted, error: error) {
                    continuation.resume(throwing: failure)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func queryRecentRecords(
        since startDate: Date,
        metrics: Set<HealthMetric>,
        perMetricLimit: Int
    ) async throws -> [HealthRecord] {
        guard isAvailable else {
            throw HealthKitServiceError.unavailable
        }

        let limit = max(1, min(perMetricLimit, 100))
        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: Date(),
            options: [.strictStartDate]
        )

        // One HealthKit query per metric; the queries overlap on HealthKit's
        // own queues, and concurrency is bounded by the metric count.
        let store = healthStore
        let recordsByMetric = try await withThrowingTaskGroup(of: (HealthMetric, [HealthRecord]).self) { group in
            for metric in HealthMetric.allCases where metrics.contains(metric) {
                group.addTask {
                    (metric, try await Self.queryRecords(
                        for: metric,
                        using: store,
                        predicate: predicate,
                        limit: limit
                    ))
                }
            }
            var results: [HealthMetric: [HealthRecord]] = [:]
            for try await (metric, records) in group {
                results[metric] = records
            }
            return results
        }

        // Assemble in HealthMetric.allCases order so the merged output stays
        // deterministic regardless of query completion order.
        var records: [HealthRecord] = []
        for metric in HealthMetric.allCases where metrics.contains(metric) {
            records.append(contentsOf: recordsByMetric[metric] ?? [])
        }

        return records.sorted { $0.startDate > $1.startDate }
    }

    func exportRecords(
        since startDate: Date,
        through endDate: Date,
        metrics: Set<HealthMetric>
    ) async throws -> HealthExportResult {
        guard isAvailable else {
            throw HealthKitServiceError.unavailable
        }
        guard !metrics.isEmpty else {
            throw HealthKitServiceError.noMetricsRequested
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: [.strictStartDate]
        )
        let store = healthStore

        // One anchored paging loop per selected metric; concurrency is
        // bounded by the metric count, and each loop is bounded by
        // SyncLimits.maxPagesPerMetric pages.
        let storeResults = try await withThrowingTaskGroup(
            of: (HealthMetric, (records: [HealthRecord], truncated: Bool)).self
        ) { group in
            for metric in HealthMetric.allCases where metrics.contains(metric) {
                group.addTask {
                    (metric, try await Self.pageAllRecords(
                        for: metric,
                        using: store,
                        predicate: predicate
                    ))
                }
            }
            var results: [HealthMetric: (records: [HealthRecord], truncated: Bool)] = [:]
            for try await (metric, result) in group {
                results[metric] = result
            }
            return results
        }

        var records: [HealthRecord] = []
        var truncatedMetrics: Set<HealthMetric> = []
        for metric in HealthMetric.allCases where metrics.contains(metric) {
            guard let result = storeResults[metric] else { continue }
            records.append(contentsOf: result.records)
            if result.truncated {
                truncatedMetrics.insert(metric)
            }
        }

        return HealthExportResult(
            records: records.sorted { ($0.startDate, $0.id.uuidString) < ($1.startDate, $1.id.uuidString) },
            truncatedMetrics: truncatedMetrics
        )
    }

    /// Nonisolated so the task-group children neither hop through the main
    /// actor nor capture the isolated service; HKHealthStore is thread-safe.
    private nonisolated static func pageAllRecords(
        for metric: HealthMetric,
        using healthStore: HKHealthStore,
        predicate: NSPredicate
    ) async throws -> (records: [HealthRecord], truncated: Bool) {
        try await RecordPager.collect(maxPages: SyncLimits.maxPagesPerMetric) { anchor in
            try await Self.queryAnchorPage(
                for: metric,
                using: healthStore,
                predicate: predicate,
                anchor: anchor,
                limit: SyncLimits.healthQueryPageSize
            )
        }
    }

    /// Nonisolated so the task-group children neither hop through the main
    /// actor nor capture the isolated service; HKHealthStore is thread-safe.
    private nonisolated static func queryRecords(
        for metric: HealthMetric,
        using healthStore: HKHealthStore,
        predicate: NSPredicate,
        limit: Int
    ) async throws -> [HealthRecord] {
        guard let sampleType = HealthKitRecordMapper.sampleType(for: metric) else {
            return []
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HealthRecord], Error>) in
            let query = HKSampleQuery(
                sampleType: sampleType,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [
                    NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
                ]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    // HKSample is not Sendable: convert to the app-owned
                    // HealthRecord value type on HealthKit's callback thread
                    // so only Sendable values cross the continuation.
                    let records = (samples ?? []).compactMap {
                        HealthKitRecordMapper.makeRecord(from: $0, metric: metric)
                    }
                    continuation.resume(returning: records)
                }
            }
            healthStore.execute(query)
        }
    }

    /// One anchored page. The anchor advances past exactly the samples it
    /// returned, so paging cannot skip records that share a start date the
    /// way a date-cursor predicate could.
    ///
    /// HKAnchoredObjectQuery is long-running: after the initial results the
    /// handler fires again whenever new matching samples are saved. Only the
    /// first callback resumes the continuation, and the query is stopped so
    /// later activity neither double-resumes (a continuation misuse trap)
    /// nor accumulates as a live observer.
    private nonisolated static func queryAnchorPage(
        for metric: HealthMetric,
        using healthStore: HKHealthStore,
        predicate: NSPredicate,
        anchor: HKQueryAnchor?,
        limit: Int
    ) async throws -> RecordPager.Page<HKQueryAnchor> {
        guard let sampleType = HealthKitRecordMapper.sampleType(for: metric) else {
            return RecordPager.Page(records: [], nextAnchor: anchor, isFull: false)
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RecordPager.Page<HKQueryAnchor>, Error>) in
            let once = ContinuationGuard()
            let queryBox = QueryBox()
            let query = HKAnchoredObjectQuery(
                type: sampleType,
                predicate: predicate,
                anchor: anchor,
                limit: limit
            ) { _, samples, _, newAnchor, error in
                guard once.claim() else { return }
                if let query = queryBox.query {
                    healthStore.stop(query)
                }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                // Map on HealthKit's callback thread so only Sendable values
                // cross the continuation.
                let records = (samples ?? []).compactMap {
                    HealthKitRecordMapper.makeRecord(from: $0, metric: metric)
                }
                continuation.resume(returning: RecordPager.Page(
                    records: records,
                    nextAnchor: newAnchor,
                    isFull: (samples?.count ?? 0) >= limit
                ))
            }
            queryBox.query = query
            healthStore.execute(query)
        }
    }

    // MARK: - Incremental changes

    func changePage(
        for metric: HealthMetric,
        since anchorData: Data?,
        windowStart: Date,
        limit: Int
    ) async throws -> HealthChangePage {
        guard isAvailable else {
            throw HealthKitServiceError.unavailable
        }
        let anchor = try Self.deserialize(anchorData)
        let predicate = HKQuery.predicateForSamples(
            withStart: windowStart,
            end: nil,
            options: [.strictStartDate]
        )
        return try await Self.queryChangePage(
            for: metric,
            using: healthStore,
            predicate: predicate,
            anchor: anchor,
            limit: limit
        )
    }

    private nonisolated static func queryChangePage(
        for metric: HealthMetric,
        using healthStore: HKHealthStore,
        predicate: NSPredicate,
        anchor: HKQueryAnchor?,
        limit: Int
    ) async throws -> HealthChangePage {
        guard let sampleType = HealthKitRecordMapper.sampleType(for: metric) else {
            return HealthChangePage(additions: [], deletions: [], anchorData: Self.serialize(anchor), isFull: false)
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HealthChangePage, Error>) in
            let once = ContinuationGuard()
            let queryBox = QueryBox()
            let query = HKAnchoredObjectQuery(
                type: sampleType,
                predicate: predicate,
                anchor: anchor,
                limit: limit
            ) { _, samples, deletedObjects, newAnchor, error in
                guard once.claim() else { return }
                if let query = queryBox.query {
                    healthStore.stop(query)
                }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                // Map on HealthKit's callback thread so only Sendable values
                // cross the continuation. Deletions are captured as events
                // here: they cannot be recovered by re-querying later.
                let additions = (samples ?? []).compactMap {
                    HealthKitRecordMapper.makeRecord(from: $0, metric: metric)
                }
                // HKDeletedObject exposes only the UUID; the deletion event
                // carries the capture time as its interval.
                let capturedAt = Date()
                let deletions = (deletedObjects ?? []).map { deleted in
                    DeletedRecord(
                        id: deleted.uuid,
                        metric: metric,
                        startDate: capturedAt,
                        endDate: capturedAt
                    )
                }
                continuation.resume(returning: HealthChangePage(
                    additions: additions,
                    deletions: deletions,
                    anchorData: Self.serialize(newAnchor),
                    // The query limit applies to new samples; a full page of
                    // additions marks a pagination boundary for the pager.
                    isFull: (samples?.count ?? 0) >= limit
                ))
            }
            queryBox.query = query
            healthStore.execute(query)
        }
    }

    // MARK: - Observers

    func observeChanges(
        for metrics: Set<HealthMetric>,
        handler: @escaping @Sendable () -> Void
    ) async throws {
        guard isAvailable else {
            throw HealthKitServiceError.unavailable
        }
        stopObservingChanges()

        let store = healthStore
        var registered: [HKObserverQuery] = []
        for metric in HealthMetric.allCases where metrics.contains(metric) {
            guard let sampleType = HealthKitRecordMapper.sampleType(for: metric) else {
                continue
            }
            let observer = HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completionHandler, _ in
                // The observer callback must complete exactly once, promptly:
                // signal the trigger, let the engine do bounded async work.
                handler()
                completionHandler()
            }
            store.execute(observer)
            registered.append(observer)
        }
        activeObservers = registered
        if !registered.isEmpty {
            // Enables background delivery for each observed type; the system
            // throttles wake-ups and never guarantees immediacy.
            for metric in HealthMetric.allCases where metrics.contains(metric) {
                guard let sampleType = HealthKitRecordMapper.sampleType(for: metric) else {
                    continue
                }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    store.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { success, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if success {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: HealthKitServiceError.authorizationFailed)
                        }
                    }
                }
            }
            hasEnabledBackgroundDelivery = true
        }
    }

    func stopObservingChanges() {
        for observer in activeObservers {
            healthStore.stop(observer)
        }
        let hadDelivery = !activeObservers.isEmpty || hasEnabledBackgroundDelivery
        activeObservers.removeAll()
        if hadDelivery {
            hasEnabledBackgroundDelivery = false
            healthStore.disableAllBackgroundDelivery { _, _ in }
        }
    }

    private var activeObservers: [HKObserverQuery] = []
    private var hasEnabledBackgroundDelivery = false

    // MARK: - Anchor serialization

    private nonisolated static func serialize(_ anchor: HKQueryAnchor?) -> Data? {
        guard let anchor else { return nil }
        return try? NSKeyedArchiver.archivedData(
            withRootObject: anchor,
            requiringSecureCoding: true
        )
    }

    private nonisolated static func deserialize(_ data: Data?) throws -> HKQueryAnchor? {
        guard let data else { return nil }
        guard let anchor = try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: HKQueryAnchor.self,
            from: data
        ) else {
            throw HealthKitServiceError.corruptedAnchor
        }
        return anchor
    }
}

enum HealthKitServiceError: LocalizedError, Equatable {
    case unavailable
    case authorizationFailed
    case noMetricsRequested
    case corruptedAnchor

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Apple Health data is not available on this device."
        case .authorizationFailed:
            "Apple Health authorization could not be completed. Grant access in Settings > Health and try again."
        case .noMetricsRequested:
            "Select at least one category in Health Data first."
        case .corruptedAnchor:
            "The stored synchronization checkpoint is unreadable; it will be rebuilt from the initial window."
        }
    }

    /// Maps HealthKit's (granted, error) authorization callback to a thrown
    /// error. `granted == false` with no error must not be read as success.
    /// `granted` reflects whether the request was processed, not the user's
    /// choice — HealthKit does not disclose read denial through this
    /// callback — so the failure branch is defensive and must not grow
    /// consent-checking logic.
    static func authorizationError(granted: Bool, error: Error?) -> Error? {
        if let error {
            return error
        }
        return granted ? nil : HealthKitServiceError.authorizationFailed
    }
}
