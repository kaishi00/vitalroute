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
    private let observers: HealthObserverCoordinator
    /// Series loaders for metrics whose records continue into a series
    /// (ECG voltage today; workout routes when cataloged). Ordinary
    /// metrics need none. Injectable so tests can script fetches; the
    /// default derives a loader for every cataloged series-capable metric
    /// so adding such a descriptor cannot silently ship without one.
    private let seriesFetchers: [HealthMetric: any SeriesFetching]

    /// `observerBackend` defaults to the store at hand; tests inject a
    /// controllable adapter so partial enablement failures, suspended
    /// registrations, and late callbacks can be scripted.
    init(
        observerBackend: (any HealthObserverBackend)? = nil,
        observerCompletionDeadline: TimeInterval = HealthObserverCoordinator.defaultCompletionDeadline,
        seriesFetchers: [HealthMetric: any SeriesFetching]? = nil
    ) {
        observers = HealthObserverCoordinator(
            backend: observerBackend ?? healthStore,
            completionDeadline: observerCompletionDeadline
        )
        self.seriesFetchers = seriesFetchers ?? Self.defaultSeriesFetchers(healthStore: healthStore)
    }

    /// A voltage loader for every catalog metric whose extraction plan
    /// continues into a series. Today no selectable metric has one; the
    /// day an ECG descriptor joins the catalog, its loader is wired by
    /// construction instead of by remembered follow-up.
    private nonisolated static func defaultSeriesFetchers(
        healthStore: HKHealthStore
    ) -> [HealthMetric: any SeriesFetching] {
        var fetchers: [HealthMetric: any SeriesFetching] = [:]
        for descriptor in MetricCatalog.metrics {
            if descriptor.extraction == .electrocardiogram {
                fetchers[descriptor.metric] = ECGVoltageSeriesFetcher(healthStore: healthStore)
            }
        }
        return fetchers
    }

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

        let types = HealthKitRecordMapper.objectTypes(for: metrics)

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
        let fetchers = seriesFetchers
        let recordsByMetric = try await withThrowingTaskGroup(of: (HealthMetric, [HealthRecord]).self) { group in
            for metric in MetricCatalog.metrics.map(\.metric) where metrics.contains(metric) {
                group.addTask {
                    let mapped = try await Self.queryRecords(
                        for: metric,
                        using: store,
                        predicate: predicate,
                        limit: limit
                    )
                    let records = try await Self.expandSeries(
                        mapped,
                        metric: metric,
                        using: store,
                        seriesFetchers: fetchers
                    )
                    return (metric, records)
                }
            }
            var results: [HealthMetric: [HealthRecord]] = [:]
            for try await (metric, records) in group {
                results[metric] = records
            }
            return results
        }

        // Assemble in catalog order so the merged output stays
        // deterministic regardless of query completion order.
        var records: [HealthRecord] = []
        for metric in MetricCatalog.metrics.map(\.metric) where metrics.contains(metric) {
            records.append(contentsOf: recordsByMetric[metric] ?? [])
        }

        return records.sorted { $0.startDate > $1.startDate }
    }

    func exportPage(
        for metric: HealthMetric,
        since anchorData: Data?,
        windowStart: Date,
        limit: Int
    ) async throws -> HealthExportPage {
        guard isAvailable else {
            throw HealthKitServiceError.unavailable
        }
        let anchor = try Self.deserialize(anchorData)
        // Fixed, open-ended predicate: an anchor is only valid with the
        // exact predicate that produced it, so the window start is frozen
        // per cursor and there is no moving end date.
        let predicate = HKQuery.predicateForSamples(
            withStart: windowStart,
            end: nil,
            options: [.strictStartDate]
        )
        let page = try await Self.queryAnchorPage(
            for: metric,
            using: healthStore,
            predicate: predicate,
            anchor: anchor,
            limit: limit
        )
        let records = try await Self.expandSeries(
            page.records,
            metric: metric,
            using: healthStore,
            seriesFetchers: seriesFetchers
        )
        return HealthExportPage(
            records: records,
            anchorData: Self.serialize(page.nextAnchor),
            isFull: page.isFull
        )
    }

    /// Nonisolated so the task-group children neither hop through the main
    /// actor nor capture the isolated service; HKHealthStore is thread-safe.
    private nonisolated static func queryRecords(
        for metric: HealthMetric,
        using healthStore: HKHealthStore,
        predicate: NSPredicate,
        limit: Int
    ) async throws -> [MappedSample] {
        guard let sampleType = HealthKitRecordMapper.sampleType(for: metric.descriptor) else {
            return []
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[MappedSample], Error>) in
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
                    // mapped values on HealthKit's callback thread so only
                    // Sendable values cross the continuation.
                    let mapped = (samples ?? []).compactMap {
                        HealthKitRecordMapper.makeMappedSample(from: $0, metric: metric)
                    }
                    continuation.resume(returning: mapped)
                }
            }
            healthStore.execute(query)
        }
    }

    /// Appends the series chunks each mapped sample asks for. A series
    /// continuation without a configured loader is a wiring bug that must
    /// fail loudly, not silently drop data.
    private nonisolated static func expandSeries(
        _ mapped: [MappedSample],
        metric: HealthMetric,
        using healthStore: HKHealthStore,
        seriesFetchers: [HealthMetric: any SeriesFetching]
    ) async throws -> [HealthRecord] {
        var records = mapped.compactMap(\.record)
        for request in mapped.compactMap(\.seriesRequest) {
            guard let fetcher = seriesFetchers[metric] else {
                throw HealthKitServiceError.seriesFetcherUnavailable(metric: metric.rawValue)
            }
            records.append(contentsOf: try await fetcher.fetchChunkRecords(for: request, metric: metric))
        }
        return records
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
    ) async throws -> RecordPager.Page<MappedSample, HKQueryAnchor> {
        guard let sampleType = HealthKitRecordMapper.sampleType(for: metric.descriptor) else {
            return RecordPager.Page(records: [], nextAnchor: anchor, isFull: false)
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RecordPager.Page<MappedSample, HKQueryAnchor>, Error>) in
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
                let mapped = (samples ?? []).compactMap {
                    HealthKitRecordMapper.makeMappedSample(from: $0, metric: metric)
                }
                continuation.resume(returning: RecordPager.Page(
                    records: mapped,
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
        let page = try await Self.queryChangePage(
            for: metric,
            using: healthStore,
            predicate: predicate,
            anchor: anchor,
            limit: limit
        )
        let additions = try await Self.expandSeries(
            page.additions,
            metric: metric,
            using: healthStore,
            seriesFetchers: seriesFetchers
        )
        return HealthChangePage(
            additions: additions,
            deletions: page.deletions,
            anchorData: page.anchorData,
            isFull: page.isFull
        )
    }

    /// Head-of-stream read: newest additions for the category, no anchor,
    /// newest first. Used by the automatic engine while a category's
    /// historical reading is throttled so fresh samples reach the
    /// destination without waiting for the backfill.
    func latestRecords(
        for metric: HealthMetric,
        windowStart: Date,
        limit: Int
    ) async throws -> [HealthRecord] {
        guard isAvailable else {
            throw HealthKitServiceError.unavailable
        }
        guard let sampleType = HealthKitRecordMapper.sampleType(for: metric.descriptor) else {
            return []
        }
        let predicate = HKQuery.predicateForSamples(
            withStart: windowStart,
            end: nil,
            options: [.strictStartDate]
        )
        let sort = NSSortDescriptor(
            key: HKSampleSortIdentifierEndDate,
            ascending: false
        )
        let fetchers = seriesFetchers
        let store = healthStore
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HealthRecord], Error>) in
            let once = ContinuationGuard()
            let query = HKSampleQuery(
                sampleType: sampleType,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                guard once.claim() else { return }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                // Map on HealthKit's callback thread so only Sendable values
                // cross the continuation. Series expansion needs async work,
                // so the callback hands over mapped samples and the task
                // expands below.
                let mapped = (samples ?? []).compactMap {
                    HealthKitRecordMapper.makeMappedSample(from: $0, metric: metric)
                }
                Task {
                    do {
                        let records = try await Self.expandSeries(
                            mapped,
                            metric: metric,
                            using: store,
                            seriesFetchers: fetchers
                        )
                        continuation.resume(returning: records)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            store.execute(query)
        }
    }

    private nonisolated static func queryChangePage(
        for metric: HealthMetric,
        using healthStore: HKHealthStore,
        predicate: NSPredicate,
        anchor: HKQueryAnchor?,
        limit: Int
    ) async throws -> (additions: [MappedSample], deletions: [DeletedRecord], anchorData: Data?, isFull: Bool) {
        guard let sampleType = HealthKitRecordMapper.sampleType(for: metric.descriptor) else {
            return ([], [], Self.serialize(anchor), false)
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<([MappedSample], [DeletedRecord], Data?, Bool), Error>) in
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
                let mapped = (samples ?? []).compactMap {
                    HealthKitRecordMapper.makeMappedSample(from: $0, metric: metric)
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
                continuation.resume(returning: (
                    mapped,
                    deletions,
                    Self.serialize(newAnchor),
                    // The query limit applies to new samples; a full page of
                    // additions marks a pagination boundary for the pager.
                    (samples?.count ?? 0) >= limit
                ))
            }
            queryBox.query = query
            healthStore.execute(query)
        }
    }

    // MARK: - Observers

    func observeChanges(
        for metrics: Set<HealthMetric>,
        handler: @escaping @Sendable (ObserverCompletion) -> Void
    ) async throws {
        guard isAvailable else {
            throw HealthKitServiceError.unavailable
        }
        let sampleTypes = HealthKitRecordMapper.sampleTypes(for: metrics)
        try await observers.start(for: sampleTypes, handler: handler)
    }

    func stopObservingChanges() async {
        await observers.stop()
    }

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
    /// A newer registration or a teardown replaced this one while it was
    /// still being established.
    case registrationSuperseded
    /// A metric whose records continue into a series was read without a
    /// series loader configured — a wiring bug, not a runtime condition.
    case seriesFetcherUnavailable(metric: String)
    /// A series continuation referenced a sample HealthKit no longer
    /// returns (deleted between the page read and the series fetch).
    case seriesSampleUnavailable(metric: String)

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
        case .registrationSuperseded:
            "Background observation was replaced before it finished starting."
        case .seriesFetcherUnavailable(let metric):
            "The \(metric) series could not be read because its loader is not configured."
        case .seriesSampleUnavailable(let metric):
            "A sample of \(metric) disappeared before its series data could be read."
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
