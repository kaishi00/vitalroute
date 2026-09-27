import Foundation
import HealthKit

/// Owns the one-shot lifecycle shared by HealthKit series queries. Query
/// installation, callback completion, cancellation, and timeout all race
/// through this coordinator so only one terminal result is delivered.
final class SeriesQueryCoordinator<Value, Query: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var terminalResult: Result<Value, Error>?
    private var isFinished = false
    private var query: Query?
    private var stopQuery: ((Query) -> Void)?
    private var queryStarted = false
    private var executionInProgress = false
    private var timeoutTask: Task<Void, Never>?

    func run(_ start: (SeriesQueryCoordinator<Value, Query>) -> Void) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                let pending: Result<Value, Error>?
                lock.lock()
                if isFinished {
                    pending = terminalResult
                } else {
                    self.continuation = continuation
                    pending = nil
                }
                lock.unlock()

                if let pending {
                    continuation.resume(with: pending)
                } else {
                    start(self)
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    /// Retain the query only while active. A cancellation that wins before
    /// installation therefore cannot leave a query-handler retention cycle.
    func installQuery(_ query: Query, stop: @escaping (Query) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return false }
        self.query = query
        stopQuery = stop
        return true
    }

    /// Execute outside the state lock. If a terminal event races with
    /// execute(), cleanup is deferred until execute() returns.
    func executeIfActive(_ execute: (Query) -> Void) -> Bool {
        lock.lock()
        guard !isFinished, let retainedQuery = query else {
            lock.unlock()
            return false
        }
        queryStarted = true
        executionInProgress = true
        lock.unlock()

        execute(retainedQuery)

        let cleanup: (Query, (Query) -> Void)?
        lock.lock()
        executionInProgress = false
        if isFinished, let query = self.query, let stop = stopQuery {
            self.query = nil
            self.stopQuery = nil
            cleanup = (query, stop)
        } else {
            cleanup = nil
        }
        lock.unlock()
        if let (query, stop) = cleanup { stop(query) }
        return true
    }

    /// Run a measurement callback while terminal callbacks wait, so the
    /// final snapshot cannot race an append and later callbacks are ignored.
    @discardableResult
    func performIfActive(_ body: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return false }
        body()
        return true
    }

    @discardableResult
    func finish(_ result: Result<Value, Error>) -> Bool {
        finish(result: { result })
    }

    @discardableResult
    func finish(result makeResult: () -> Result<Value, Error>) -> Bool {
        let continuation: CheckedContinuation<Value, Error>?
        let result: Result<Value, Error>
        let timeout: Task<Void, Never>?
        let cleanup: (Query, (Query) -> Void)?

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return false
        }
        result = makeResult()
        isFinished = true
        terminalResult = result
        continuation = self.continuation
        self.continuation = nil
        timeout = timeoutTask
        timeoutTask = nil
        if queryStarted && !executionInProgress, let query, let stopQuery {
            self.query = nil
            self.stopQuery = nil
            cleanup = (query, stopQuery)
        } else {
            // An unstarted query is simply released. If execute is in flight,
            // executeIfActive performs the stop after it returns.
            if !executionInProgress {
                query = nil
                stopQuery = nil
            }
            cleanup = nil
        }
        lock.unlock()

        timeout?.cancel()
        if let (query, stop) = cleanup { stop(query) }
        continuation?.resume(with: result)
        return true
    }

    func scheduleTimeout(after nanoseconds: UInt64) {
        let task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
                self?.finish(.failure(HealthKitServiceError.seriesQueryTimedOut))
            } catch {
                // Completion/cancellation invalidates the deadline.
            }
        }
        lock.lock()
        if isFinished {
            lock.unlock()
            task.cancel()
        } else {
            timeoutTask?.cancel()
            timeoutTask = task
            lock.unlock()
        }
    }
}

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
/// on HealthKit queues; a lock-protected collector serializes measurements
/// with terminal snapshots, so only Sendable values cross into concurrency.
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
        let coordinator = SeriesQueryCoordinator<HKElectrocardiogram, HKSampleQuery>()
        return try await coordinator.run { operation in
            operation.scheduleTimeout(after: Self.queryTimeoutNanoseconds)
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    operation.finish(.failure(error))
                } else if let ecg = samples?.first as? HKElectrocardiogram {
                    operation.finish(.success(ecg))
                } else {
                    operation.finish(.failure(HealthKitServiceError.seriesSampleUnavailable(metric: "electrocardiogram")))
                }
            }
            guard operation.installQuery(query, stop: { self.healthStore.stop($0) }) else { return }
            _ = operation.executeIfActive { self.healthStore.execute($0) }
        }
    }

    /// Streams voltage measurements until the query reports done. Only the
    /// first terminal callback resumes, and a deadline prevents this
    /// long-running query from suspending synchronization indefinitely. The
    /// query coordinator explicitly releases its query when it terminates.
    private func fetchPoints(ecg: HKElectrocardiogram) async throws -> [[Double]] {
        let collector = MeasurementCollector()
        let microvolts = HKUnit.voltUnit(with: .micro)
        let coordinator = SeriesQueryCoordinator<[[Double]], HKElectrocardiogramQuery>()
        return try await coordinator.run { operation in
            operation.scheduleTimeout(after: Self.queryTimeoutNanoseconds)
            let query = HKElectrocardiogramQuery(ecg) { _, result in
                switch result {
                case .error(let error):
                    operation.finish(.failure(error))
                case .measurement(let measurement):
                    // Apple Watch ECGs carry a single lead.
                    if let voltage = measurement.quantity(for: .appleWatchSimilarToLeadI) {
                        operation.performIfActive {
                            collector.append(
                                time: measurement.timeSinceSampleStart,
                                voltage: voltage.doubleValue(for: microvolts)
                            )
                        }
                    }
                case .done:
                    operation.finish(result: { .success(collector.collected()) })
                @unknown default:
                    // A future result kind carries no data this fetcher
                    // needs; the terminal `.done` still ends the fetch.
                    break
                }
            }
            guard operation.installQuery(query, stop: { self.healthStore.stop($0) }) else { return }
            _ = operation.executeIfActive { self.healthStore.execute($0) }
        }
    }

    /// Bounds each HealthKit query in the ECG fetch: the sample lookup and
    /// voltage stream each get up to sixty seconds, so the sequential fetch
    /// can take up to two minutes before returning a timeout to its caller.
    private static let queryTimeoutNanoseconds: UInt64 = 60_000_000_000

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
