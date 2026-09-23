import Foundation
import HealthKit

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
            end: Date(),
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
            let query = HKAnchoredObjectQuery(
                type: sampleType,
                predicate: predicate,
                anchor: anchor,
                limit: limit
            ) { _, samples, _, newAnchor, error in
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
            healthStore.execute(query)
        }
    }
}

enum HealthKitServiceError: LocalizedError, Equatable {
    case unavailable
    case authorizationFailed
    case noMetricsRequested

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Apple Health data is not available on this device."
        case .authorizationFailed:
            "Apple Health authorization could not be completed. Grant access in Settings > Health and try again."
        case .noMetricsRequested:
            "Select at least one category in Health Data first."
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
