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

    private func syntheticPayload(count: Int) -> SyncPayload {
        let base = Date(timeIntervalSince1970: 1_760_000_000)
        var records: [HealthRecord] = []
        records.reserveCapacity(count)
        for index in 0..<count {
            let isSteps = index % 2 == 0
            let offsetMinutes = Double(index) * 60
            let record = HealthRecord(
                id: UUID(),
                metric: isSteps ? .steps : .heartRate,
                value: Double(60 + index),
                unit: isSteps ? "count" : "count/min",
                startDate: base.addingTimeInterval(offsetMinutes),
                endDate: base.addingTimeInterval(offsetMinutes + 30)
            )
            records.append(record)
        }
        return SyncPayload(records: records)
    }

    func testConnectionTestAgainstLiveReceiver() async throws {
        let configuration = try integrationConfiguration()
        let authorization = DestinationAuthorization(bearerToken: configuration.token)
        let client = self.client

        let response = try await awaitWithTimeout {
            try await client.testConnection(to: configuration.endpoint, authorization: authorization)
        }

        XCTAssertEqual(response.status, "ok")
        XCTAssertEqual(response.apiVersion, 1)
    }

    func testIngestionRetryIsIdempotentAgainstLiveReceiver() async throws {
        let configuration = try integrationConfiguration()
        let authorization = DestinationAuthorization(bearerToken: configuration.token)
        let client = self.client
        let endpoint = configuration.endpoint
        let payload = syntheticPayload(count: 6)

        let first = try await awaitWithTimeout {
            try await client.send(payload, to: endpoint, authorization: authorization)
        }
        XCTAssertEqual(first.accepted, 6)
        XCTAssertEqual(first.duplicates, 0)

        // Retrying the identical batch must not duplicate records.
        let retry = try await awaitWithTimeout {
            try await client.send(payload, to: endpoint, authorization: authorization)
        }
        XCTAssertEqual(retry.accepted, 0)
        XCTAssertEqual(retry.duplicates, 6)
    }

    func testWrongTokenIsRejectedByLiveReceiver() async throws {
        let configuration = try integrationConfiguration()
        let authorization = DestinationAuthorization(bearerToken: "wrong-token-0123456789")
        let client = self.client
        let payload = syntheticPayload(count: 2)

        do {
            _ = try await awaitWithTimeout {
                try await client.send(payload, to: configuration.endpoint, authorization: authorization)
            }
            XCTFail("expected authentication failure")
        } catch let error as DestinationClientError {
            XCTAssertEqual(error, .authenticationFailed)
        }
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
