import XCTest
@testable import VitalRoute

/// Live integration against a real reference receiver (`server/receiver.py`).
///
/// Skipped unless the harness provides both environment variables:
/// - `VITALROUTE_INTEGRATION_URL` — the receiver's ingestion endpoint over
///   HTTPS (normal certificate validation applies; do not weaken it).
/// - `VITALROUTE_INTEGRATION_TOKEN` — the receiver's bearer token.
///
/// Unlike HTTPDestinationClientTests (mocked transport), this exercises the
/// production URLSession stack, real TLS, real HTTP framing, and the real
/// receiver's validation, transactional persistence, and idempotency.
/// HealthKit data is never involved: records are synthetic.
final class ReceiverIntegrationTests: XCTestCase {
    private var client: HTTPDestinationClient {
        HTTPDestinationClient()
    }

    private func integrationConfiguration() throws -> (endpoint: URL, token: String) {
        let environment = ProcessInfo.processInfo.environment
        let rawURL = environment["VITALROUTE_INTEGRATION_URL"]
        let token = environment["VITALROUTE_INTEGRATION_TOKEN"]
        guard let rawURL else {
            throw XCTSkip(missingEnvironmentMessage)
        }
        guard let token, !token.isEmpty else {
            throw XCTSkip(missingEnvironmentMessage)
        }
        guard let url = URL(string: rawURL), url.scheme == "https" else {
            throw XCTSkip("VITALROUTE_INTEGRATION_URL must be an HTTPS URL.")
        }
        return (url, token)
    }

    private let missingEnvironmentMessage =
        "Set VITALROUTE_INTEGRATION_URL and VITALROUTE_INTEGRATION_TOKEN to run the live receiver integration."

    /// Synthetic records covering every contract-v3 kind. Ids are unique
    /// per call, so retries of the SAME batch are idempotent while different
    /// tests never collide.
    private func syntheticChanges(count: Int) -> [SyncChangeEvent] {
        let base = Date(timeIntervalSince1970: 1_760_000_000)
        let seriesID = UUID()
        var changes: [SyncChangeEvent] = []
        changes.reserveCapacity(count)
        for index in 0..<count {
            let offset = Double(index) * 60
            let start = base.addingTimeInterval(offset)
            let end = start.addingTimeInterval(30)
            let record: HealthRecord
            switch index % 6 {
            case 0:
                record = HealthRecord(
                    id: UUID(), metric: .steps, startDate: start, endDate: end,
                    data: .quantity(QuantityData(value: Double(8000 + index), unit: "count")))
            case 1:
                record = HealthRecord(
                    id: UUID(), metric: .heartRate, startDate: start, endDate: end,
                    data: .quantity(QuantityData(value: Double(60 + index), unit: "count/min")))
            case 2:
                record = HealthRecord(
                    id: UUID(), metric: .sleep, startDate: start, endDate: start.addingTimeInterval(1800),
                    data: .category(CategoryData(value: 3, name: "asleepREM")))
            case 3:
                record = HealthRecord(
                    id: UUID(), metric: HealthMetric(rawValue: "bloodPressure")!, startDate: start, endDate: start,
                    data: .correlation(CorrelationData(components: [
                        CorrelationComponent(metric: "bloodPressureSystolic", value: 122, unit: "mmHg"),
                        CorrelationComponent(metric: "bloodPressureDiastolic", value: 78, unit: "mmHg"),
                    ])))
            case 4:
                record = HealthRecord(
                    id: UUID(), metric: .workouts, startDate: start, endDate: end,
                    data: .workout(WorkoutData(
                        activityType: "running",
                        activityTypeRawValue: 52,
                        duration: 1920,
                        totalEnergyKilocalories: 331,
                        totalDistanceMeters: 5210)))
            default:
                record = HealthRecord(
                    id: HealthKitRecordMapper.deterministicChunkID(seriesID: seriesID, chunkIndex: index / 6),
                    metric: .heartRate, startDate: start, endDate: end,
                    data: .series(SeriesData(
                        seriesType: "syntheticSeries",
                        seriesID: seriesID,
                        parentID: nil,
                        chunkIndex: index / 6,
                        channels: ["t", "v"],
                        points: [[0, 1], [0.5, 2], [1, 3]])))
            }
            changes.append(.upsert(record))
        }
        return changes
    }

    func testConnectionTestAgainstLiveReceiver() async throws {
        let configuration = try integrationConfiguration()
        let authorization = DestinationAuthorization(bearerToken: configuration.token)
        let client = self.client

        let response = try await awaitWithTimeout {
            try await client.testConnection(to: configuration.endpoint, authorization: authorization)
        }

        XCTAssertEqual(response.status, "ok")
        XCTAssertEqual(response.apiVersion, 3)
        XCTAssertTrue(response.supportsDeletions, "the live receiver must advertise deletion support for this suite")
    }

    func testIngestionRetryIsIdempotentAgainstLiveReceiver() async throws {
        let configuration = try integrationConfiguration()
        let authorization = DestinationAuthorization(bearerToken: configuration.token)
        let client = self.client
        let endpoint = configuration.endpoint
        let changes = syntheticChanges(count: 6)

        let first = try await awaitWithTimeout {
            try await client.sendChanges(changes, batchID: UUID(), to: endpoint, authorization: authorization)
        }
        XCTAssertEqual(first.accepted, 6)
        XCTAssertEqual(first.duplicates, 0)

        // Retrying the identical batch must not duplicate records.
        let retry = try await awaitWithTimeout {
            try await client.sendChanges(changes, batchID: UUID(), to: endpoint, authorization: authorization)
        }
        XCTAssertEqual(retry.accepted, 0)
        XCTAssertEqual(retry.duplicates, 6)
    }

    func testWrongTokenIsRejectedByLiveReceiver() async throws {
        let configuration = try integrationConfiguration()
        let authorization = DestinationAuthorization(bearerToken: "wrong-token-0123456789")
        let client = self.client
        let changes = syntheticChanges(count: 2)

        do {
            _ = try await awaitWithTimeout {
                try await client.sendChanges(changes, batchID: UUID(), to: configuration.endpoint, authorization: authorization)
            }
            XCTFail("expected authentication failure")
        } catch let error as DestinationClientError {
            XCTAssertEqual(error, .authenticationFailed)
        }
    }

    func testChangeLifecycleAgainstLiveReceiver() async throws {
        // Addition -> retry (idempotent) -> deletion -> old-addition replay
        // (tombstone must prevent resurrection), each through the real
        // client against the real receiver over real TLS.
        let configuration = try integrationConfiguration()
        let authorization = DestinationAuthorization(bearerToken: configuration.token)
        let client = self.client
        let endpoint = configuration.endpoint

        let keepID = UUID()
        let dropID = UUID()
        let base = Date(timeIntervalSince1970: 1_760_100_000)
        @Sendable func upsertEvent(_ id: UUID, offset: TimeInterval) -> SyncChangeEvent {
            .upsert(HealthRecord(
                id: id,
                metric: .steps,
                startDate: base.addingTimeInterval(offset),
                endDate: base.addingTimeInterval(offset + 60),
                data: .quantity(QuantityData(value: 100, unit: "count"))
            ))
        }
        let initial: [SyncChangeEvent] = [
            upsertEvent(keepID, offset: 0),
            upsertEvent(dropID, offset: 120),
        ]

        // 1) Addition.
        let added = try await awaitWithTimeout {
            try await client.sendChanges(initial, batchID: UUID(), to: endpoint, authorization: authorization)
        }
        XCTAssertEqual(added.accepted, 2)
        XCTAssertEqual(added.duplicates, 0)

        // 2) Retry of the same batch is idempotent.
        let retried = try await awaitWithTimeout {
            try await client.sendChanges(initial, batchID: UUID(), to: endpoint, authorization: authorization)
        }
        XCTAssertEqual(retried.accepted, 0)
        XCTAssertEqual(retried.duplicates, 2)

        // 3) Deletion of one sample.
        let deletion = SyncChangeEvent.delete(DeletedRecord(
            id: dropID,
            metric: .steps,
            startDate: base,
            endDate: base.addingTimeInterval(60)
        ))
        let deleted = try await awaitWithTimeout {
            try await client.sendChanges([deletion], batchID: UUID(), to: endpoint, authorization: authorization)
        }
        XCTAssertEqual(deleted.appliedDeletions, 1)
        XCTAssertEqual(deleted.duplicateDeletions, 0)

        // 4) Old queued addition replayed after the deletion must not
        //    resurrect the deleted sample.
        let resurrectAttempt = try await awaitWithTimeout {
            try await client.sendChanges([upsertEvent(dropID, offset: 120)], batchID: UUID(), to: endpoint, authorization: authorization)
        }
        XCTAssertEqual(resurrectAttempt.superseded, 1)
        XCTAssertEqual(resurrectAttempt.accepted, 0)

        // 5) The deletion retry also stays idempotent.
        let deletionRetry = try await awaitWithTimeout {
            try await client.sendChanges([deletion], batchID: UUID(), to: endpoint, authorization: authorization)
        }
        XCTAssertEqual(deletionRetry.appliedDeletions, 0)
        XCTAssertEqual(deletionRetry.duplicateDeletions, 1)
    }

    // MARK: Helpers

    private func awaitWithTimeout<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let box = ResultBox<T>()
        let expectation = expectation(description: "network operation completed")
        Task {
            do {
                box.store(.success(try await operation()))
            } catch {
                box.store(.failure(error))
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 30)
        return try box.storedResult().get()
    }
}

/// Thread-safe result handoff from the network task back to the test body.
private final class ResultBox<T>: @unchecked Sendable {
    private struct TimeoutError: Error {}

    private let lock = NSLock()
    private var result: Result<T, Error>?

    func store(_ result: Result<T, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func storedResult() throws -> Result<T, Error> {
        lock.lock()
        defer { lock.unlock() }
        guard let result else {
            // A live-receiver operation that never completed must fail the
            // test, not silently skip it.
            return .failure(TimeoutError())
        }
        return result
    }
}
