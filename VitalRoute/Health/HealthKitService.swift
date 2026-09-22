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
            healthStore.requestAuthorization(toShare: Set<HKSampleType>(), read: types) { _, error in
                if let error {
                    continuation.resume(throwing: error)
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

        var records: [HealthRecord] = []
        for metric in HealthMetric.allCases {
            guard let type = HealthKitRecordMapper.sampleType(for: metric) else {
                continue
            }
            let samples = try await querySamples(of: type, predicate: predicate, limit: limit)
            records.append(contentsOf: samples.compactMap {
                HealthKitRecordMapper.makeRecord(from: $0, metric: metric)
            })
        }

        return records.sorted { $0.startDate > $1.startDate }
    }

    private func querySamples(
        of sampleType: HKSampleType,
        predicate: NSPredicate,
        limit: Int
    ) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], Error>) in
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
                    continuation.resume(returning: samples ?? [])
                }
            }
            healthStore.execute(query)
        }
    }
}

private enum HealthKitServiceError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Apple Health data is not available on this device."
    }
}
