import Foundation
import HealthKit

/// Loads the series payloads that continue a parent sample: the voltage
/// measurements behind an ECG, and (when a future catalog metric exposes
/// them) the locations behind a workout route. Adapters own the
/// HealthKit-specific queries; the chunking itself lives in
/// `HealthKitRecordMapper.seriesChunkRecords`, which is unit-tested.
protocol SeriesFetching: Sendable {
    /// Chunk records for one parent sample's series. The returned records
    /// carry deterministic chunk UUIDs, so a retried fetch dedupes at the
    /// receiver.
    func fetchChunkRecords(for request: SeriesRequest, metric: HealthMetric) async throws -> [HealthRecord]
}

/// Fetches an ECG's voltage measurements and chunks them into `series`
/// records (`seriesType` "electrocardiogramVoltage", channels [t,
/// microvolts]).
///
/// `HKElectrocardiogramQuery` needs the `HKElectrocardiogram` object, which
/// does not survive the mapper's Sendable boundary; the fetcher therefore
/// re-reads the sample by its UUID (the same object HealthKit mapped a
/// moment ago) and then streams the voltage query. The query handlers run
/// on HealthKit queues; an actor collects measurements so only Sendable
/// values cross back into structured concurrency.
///
/// Unit tests exercise the chunking and identity math, not this adapter:
/// HKElectrocardiogram cannot be constructed outside HealthKit.
struct ECGVoltageSeriesFetcher: SeriesFetching {
    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore) {
        self.healthStore = healthStore
    }

    func fetchChunkRecords(for request: SeriesRequest, metric: HealthMetric) async throws -> [HealthRecord] {
        let ecg = try await loadElectrocardiogram(id: request.seriesID)
        let points = try await fetchPoints(ecg: ecg)
        guard !points.isEmpty else { return [] }
        return HealthKitRecordMapper.seriesChunkRecords(
            seriesType: "electrocardiogramVoltage",
            seriesID: request.seriesID,
            parentID: request.parentID,
            channels: ["t", "microvolts"],
            points: points,
            metric: metric,
            parentStart: request.parentStart,
            parentEnd: request.parentEnd
        )
    }

    private func loadElectrocardiogram(id: UUID) async throws -> HKElectrocardiogram {
        let type = HKObjectType.electrocardiogramType()
        let predicate = HKQuery.predicateForObjects(with: [id])
        return try await withCheckedThrowingContinuation { continuation in
            let once = ContinuationGuard()
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, error in
                guard once.claim() else { return }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let ecg = samples?.first as? HKElectrocardiogram {
                    continuation.resume(returning: ecg)
                } else {
                    continuation.resume(throwing: HealthKitServiceError.seriesSampleUnavailable(metric: "electrocardiogram"))
                }
            }
            healthStore.execute(query)
        }
    }

    /// Streams voltage measurements until the query reports done. Only the
    /// first terminal callback resumes — HealthKit does not promise the
    /// error/done events are mutually exclusive — and the query is stopped
    /// at that point so later measurements cannot accumulate unowned. The
    /// actor keeps collection off the callback thread's type.
    private func fetchPoints(ecg: HKElectrocardiogram) async throws -> [[Double]] {
        let collector = MeasurementCollector()
        let microvolts = HKUnit.voltUnit(with: .micro)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ContinuationGuard()
            let queryBox = ECGQueryBox()
            let query = HKElectrocardiogramQuery(ecg) { _, result in
                switch result {
                case .error(let error):
                    guard once.claim() else { return }
                    if let query = queryBox.query {
                        self.healthStore.stop(query)
                    }
                    continuation.resume(throwing: error)
                case .measurement(let measurement):
                    // Apple Watch ECGs carry a single lead.
                    if let voltage = measurement.quantity(for: .appleWatchSimilarToLeadI) {
                        collector.append(
                            time: measurement.timeSinceSampleStart,
                            voltage: voltage.doubleValue(for: microvolts)
                        )
                    }
                case .done:
                    guard once.claim() else { return }
                    if let query = queryBox.query {
                        self.healthStore.stop(query)
                    }
                    continuation.resume()
                @unknown default:
                    // A future result kind carries no data this fetcher
                    // needs; the terminal `.done` still ends the fetch.
                    break
                }
            }
            queryBox.query = query
            healthStore.execute(query)
        }
        return collector.collected()
    }

    /// Holds the query reference so the terminal callback can stop the
    /// long-running voltage query; the callback closure cannot capture the
    /// query it is being constructed into. The box is intentionally part of
    /// a retain cycle (query → handler → box → query): HealthKit releases
    /// the handler when `stop(_:)` runs, which is what breaks the cycle.
    private final class ECGQueryBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedQuery: HKElectrocardiogramQuery?

        var query: HKElectrocardiogramQuery? {
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

    private final class MeasurementCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var points: [[Double]] = []

        func append(time: TimeInterval, voltage: Double) {
            lock.lock()
            defer { lock.unlock() }
            points.append([time, voltage])
        }

        func collected() -> [[Double]] {
            lock.lock()
            defer { lock.unlock() }
            return points
        }
    }
}
