import Foundation
import HealthKit

@MainActor
final class HealthKitService: HealthDataProviding {
    private let healthStore = HKHealthStore()

    var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func requestReadAuthorization() async throws {
        guard isAvailable else {
            throw HealthKitServiceError.unavailable
        }

        let types = Set(HealthMetric.allCases.compactMap { metric -> HKObjectType? in
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

    func queryRecentRecords(since startDate: Date, perMetricLimit: Int) async throws -> [HealthRecord] {
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
        // own queues, and concurrency is bounded by the fixed metric count.
        let store = healthStore
        let recordsByMetric = try await withThrowingTaskGroup(of: (HealthMetric, [HealthRecord]).self) { group in
            for metric in HealthMetric.allCases {
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
        for metric in HealthMetric.allCases {
            records.append(contentsOf: recordsByMetric[metric] ?? [])
        }

        return records.sorted { $0.startDate > $1.startDate }
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
}

enum HealthKitServiceError: LocalizedError, Equatable {
    case unavailable
    case authorizationFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Apple Health data is not available on this device."
        case .authorizationFailed:
            "Apple Health authorization could not be completed. Grant access in Settings > Health and try again."
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
