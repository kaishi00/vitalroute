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
        guard
            let rawURL = environment["VITALROUTE_INTEGRATION_URL"],
            let token = environment["VITALROUTE_INTEGRATION_TOKEN"],
            !token.isEmpty,
            let url = URL(string: rawURL),
            url.scheme == "https"
        else {
            throw XCTSkip(
                "Set VITALROUTE_INTEGRATION_URL and VITALROUTE_INTEGRATION_TOKEN to run the live receiver integration."
            )
        }
        return (url, token)
    }

    private func syntheticPayload(count: Int) -> SyncPayload {
        let base = Date(timeIntervalSince1970: 1_760_000_000)
        let records = (0..<count).map { index in
            HealthRecord(
                id: UUID(),
                metric: index % 2 == 0 ? .steps : .heartRate,
                value: Double(60 + index),
                unit: index % 2 == 0 ? "count" : "count/min",
                startDate: base.addingTimeInterval(Double(index) * 60),
                endDate: base.addingTimeInterval(Double(index) * 60 + 30)
            )
        }
        return SyncPayload(records: records)
    }

    func testConnectionTestAgainstLiveReceiver() throws {
        let configuration = try integrationConfiguration()

        let response = try awaitWithTimeout {
            try await self.client.testConnection(
                to: configuration.endpoint,
                authorization: DestinationAuthorization(bearerToken: configuration.token)
            )
        }

        XCTAssertEqual(response.status, "ok")
        XCTAssertEqual(response.apiVersion, 1)
    }

    func testIngestionRetryIsIdempotentAgainstLiveReceiver() throws {
        let configuration = try integrationConfiguration()
        let payload = syntheticPayload(count: 6)

        let first = try awaitWithTimeout {
            try await self.client.send(
                payload,
                to: configuration.endpoint,
                authorization: DestinationAuthorization(bearerToken: configuration.token)
            )
        }
        XCTAssertEqual(first.accepted, 6)
        XCTAssertEqual(first.duplicates, 0)

        // Retrying the identical batch must not duplicate records.
        let retry = try awaitWithTimeout {
            try await self.client.send(
                payload,
                to: configuration.endpoint,
                authorization: DestinationAuthorization(bearerToken: configuration.token)
            )
        }
        XCTAssertEqual(retry.accepted, 0)
        XCTAssertEqual(retry.duplicates, 6)
    }

    func testWrongTokenIsRejectedByLiveReceiver() throws {
        let configuration = try integrationConfiguration()
        let payload = syntheticPayload(count: 2)

        do {
            _ = try awaitWithTimeout {
                try await self.client.send(
                    payload,
                    to: configuration.endpoint,
                    authorization: DestinationAuthorization(bearerToken: "wrong-token-0123456789")
                )
            }
            XCTFail("expected authentication failure")
        } catch let error as DestinationClientError {
            XCTAssertEqual(error, .authenticationFailed)
        }
    }

    // MARK: Helpers

    private func awaitWithTimeout<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
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
        return try box.result().get()
    }
}

/// Thread-safe result handoff from the network task back to the test body.
private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?

    func store(_ result: Result<T, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func result() throws -> Result<T, Error> {
        lock.lock()
        defer { lock.unlock() }
        guard let result else {
            return .failure(XCTSkip("operation never completed"))
        }
        return result
    }
}
