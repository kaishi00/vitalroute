import XCTest
@testable import VitalRoute

/// Mocked-transport tests for the receiver-contract client. Every test
/// supplies its own transport closure; nothing here touches the network.
/// Real-receiver behavior is covered separately by ReceiverIntegrationTests.
final class HTTPDestinationClientTests: XCTestCase {
    private let endpoint = URL(string: "https://health.example.org/v1/records")!
    private let authorization = DestinationAuthorization(bearerToken: "test-token-0123456789")

    private func httpData(_ json: String) -> Data {
        Data(json.utf8)
    }

    private func httpResponse(status: Int, url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    private func sampleRecord() -> HealthRecord {
        HealthRecord(
            metric: .steps,
            startDate: Date(timeIntervalSince1970: 1_735_689_600),
            endDate: Date(timeIntervalSince1970: 1_735_689_600),
            data: .quantity(QuantityData(value: 100, unit: "count"))
        )
    }

    private func sampleChanges() -> [SyncChangeEvent] {
        [.upsert(sampleRecord())]
    }

    // MARK: Request construction

    /// Thread-safe capture of the request the transport received; the
    /// transport closure is @Sendable, so a bare captured var would warn
    /// under Swift 6 concurrency.
    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedRequest: URLRequest?

        var request: URLRequest? {
            lock.lock()
            defer { lock.unlock() }
            return storedRequest
        }

        func store(_ request: URLRequest) {
            lock.lock()
            storedRequest = request
            lock.unlock()
        }
    }

    func testSendBuildsContractRequest() async throws {
        let box = RequestBox()
        let client = HTTPDestinationClient { request in
            box.store(request)
            return (
                self.httpData(#"{"status":"accepted","accepted":1,"duplicates":0,"superseded":0,"appliedDeletions":0,"duplicateDeletions":0}"#),
                self.httpResponse(status: 200, url: request.url!)
            )
        }

        let acknowledgment = try await client.sendChanges(
            sampleChanges(),
            batchID: UUID(),
            to: endpoint,
            authorization: authorization
        )

        XCTAssertEqual(acknowledgment.accepted, 1)
        XCTAssertEqual(acknowledgment.duplicates, 0)
        let request = try XCTUnwrap(box.request)
        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token-0123456789")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        // The body is a contract v3 change batch the receiver accepts.
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(decoded?["schemaVersion"] as? Int, 3)
        let changes = try XCTUnwrap(decoded?["changes"] as? [[String: Any]])
        XCTAssertEqual(changes.count, 1)
        let record = try XCTUnwrap(changes.first?["record"] as? [String: Any])
        XCTAssertEqual(record["metric"] as? String, "steps")
        let data = try XCTUnwrap(record["data"] as? [String: Any])
        XCTAssertEqual(data["type"] as? String, "quantity")
    }

    func testTestConnectionSendsGETWithNoBody() async throws {
        let box = RequestBox()
        let client = HTTPDestinationClient { request in
            box.store(request)
            return (
                self.httpData(#"{"status":"ok","service":"vitalroute-receiver","apiVersion":1}"#),
                self.httpResponse(status: 200, url: request.url!)
            )
        }

        let response = try await client.testConnection(to: endpoint, authorization: authorization)

        XCTAssertEqual(response, ReceiverHealthResponse(status: "ok", service: "vitalroute-receiver", apiVersion: 1, capabilities: []))
        let request = try XCTUnwrap(box.request)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.httpBodyStream)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token-0123456789")
    }

    // MARK: Acknowledgment validation

    func testValidAcknowledgmentDecodes() async throws {
        let client = HTTPDestinationClient { request in
            (
                self.httpData(#"{"status":"accepted","accepted":12,"duplicates":3,"superseded":0,"appliedDeletions":0,"duplicateDeletions":0,"schemaVersion":3}"#),
                self.httpResponse(status: 200, url: request.url!)
            )
        }

        // Acknowledgment counts must account for the whole batch; send 15
        // upserts to match the 12 new + 3 duplicates the receiver reports.
        let changes: [SyncChangeEvent] = (0..<15).map { index in
            .upsert(HealthRecord(
                metric: .steps,
                startDate: Date(timeIntervalSince1970: 1_735_689_600),
                endDate: Date(timeIntervalSince1970: 1_735_689_600),
                data: .quantity(QuantityData(value: Double(index), unit: "count"))
            ))
        }
        let acknowledgment = try await client.sendChanges(
            changes,
            batchID: UUID(),
            to: endpoint,
            authorization: authorization
        )

        XCTAssertEqual(acknowledgment.accepted, 12)
        XCTAssertEqual(acknowledgment.duplicates, 3)
        XCTAssertEqual(acknowledgment.superseded, 0)
    }

    func testWrongAcknowledgmentStatusIsMalformed() async {
        let client = HTTPDestinationClient { request in
            (
                self.httpData(#"{"status":"queued","accepted":1,"duplicates":0}"#),
                self.httpResponse(status: 200, url: request.url!)
            )
        }

        await assertThrows(.malformedAcknowledgment) {
            _ = try await client.sendChanges(sampleChanges(), batchID: UUID(), to: self.endpoint, authorization: self.authorization)
        }
    }

    func testMissingAcknowledgmentCountsAreMalformed() async {
        let client = HTTPDestinationClient { request in
            (self.httpData(#"{"status":"accepted"}"#), self.httpResponse(status: 200, url: request.url!))
        }

        await assertThrows(.malformedAcknowledgment) {
            _ = try await client.sendChanges(sampleChanges(), batchID: UUID(), to: self.endpoint, authorization: self.authorization)
        }
    }

    func testNonJSONAcknowledgmentIsMalformed() async {
        let client = HTTPDestinationClient { request in
            (self.httpData("<html>ok</html>"), self.httpResponse(status: 200, url: request.url!))
        }

        await assertThrows(.malformedAcknowledgment) {
            _ = try await client.sendChanges(sampleChanges(), batchID: UUID(), to: self.endpoint, authorization: self.authorization)
        }
    }

    func testEmptyAcknowledgmentBodyIsMalformed() async {
        let client = HTTPDestinationClient { request in
            (Data(), self.httpResponse(status: 200, url: request.url!))
        }

        await assertThrows(.malformedAcknowledgment) {
            _ = try await client.sendChanges(sampleChanges(), batchID: UUID(), to: self.endpoint, authorization: self.authorization)
        }
    }

    // MARK: Status mapping

    func testUnauthorizedAndForbiddenMapToAuthenticationFailure() async {
        for status in [401, 403] {
            let client = HTTPDestinationClient { request in
                (Data(), self.httpResponse(status: status, url: request.url!))
            }
            await assertThrows(.authenticationFailed) {
                _ = try await client.sendChanges(sampleChanges(), batchID: UUID(), to: self.endpoint, authorization: self.authorization)
            }
        }
    }

    func testRedirectResponseIsRejected() async {
        let client = HTTPDestinationClient { request in
            (
                Data(),
                self.httpResponse(status: 302, url: request.url!)
            )
        }

        await assertThrows(.redirected) {
            _ = try await client.sendChanges(sampleChanges(), batchID: UUID(), to: self.endpoint, authorization: self.authorization)
        }
        await assertThrows(.redirected) {
            _ = try await client.testConnection(to: self.endpoint, authorization: self.authorization)
        }
    }

    func testPayloadTooLargeMaps() async {
        let client = HTTPDestinationClient { request in
            (Data(), self.httpResponse(status: 413, url: request.url!))
        }

        await assertThrows(.payloadTooLarge) {
            _ = try await client.sendChanges(sampleChanges(), batchID: UUID(), to: self.endpoint, authorization: self.authorization)
        }
    }

    func testServerErrorsMapWithStatus() async {
        let client = HTTPDestinationClient { request in
            (
                self.httpData(#"{"error":{"code":"invalid_json","message":"nope"}}"#),
                self.httpResponse(status: 400, url: request.url!)
            )
        }

        await assertThrows(.serverRejected(status: 400)) {
            _ = try await client.sendChanges(sampleChanges(), batchID: UUID(), to: self.endpoint, authorization: self.authorization)
        }
    }

    // MARK: Transport error mapping

    func testURLErrorTimeoutMaps() async {
        let client = HTTPDestinationClient { _ in
            throw URLError(.timedOut)
        }

        await assertThrows(.requestTimedOut) {
            _ = try await client.sendChanges(sampleChanges(), batchID: UUID(), to: self.endpoint, authorization: self.authorization)
        }
    }

    func testURLErrorCannotConnectMaps() async {
        let client = HTTPDestinationClient { _ in
            throw URLError(.cannotConnectToHost)
        }

        await assertThrows(.connectionFailed) {
            _ = try await client.sendChanges(sampleChanges(), batchID: UUID(), to: self.endpoint, authorization: self.authorization)
        }
    }

    func testNonHTTPResponseIsInvalid() async {
        let client = HTTPDestinationClient { request in
            (Data(), URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        }

        await assertThrows(.invalidResponse) {
            _ = try await client.sendChanges(sampleChanges(), batchID: UUID(), to: self.endpoint, authorization: self.authorization)
        }
    }

    func testCancelledURLErrorSurfacesAsCancellation() async {
        let client = HTTPDestinationClient { _ in
            throw URLError(.cancelled)
        }

        do {
            _ = try await client.sendChanges(sampleChanges(), batchID: UUID(), to: endpoint, authorization: authorization)
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    // MARK: Fail-closed transport hardening

    func testPlainHTTPEndpointsAreRefused() async {
        let client = HTTPDestinationClient { _ in
            XCTFail("transport must not be invoked for a non-HTTPS endpoint")
            return (Data(), self.httpResponse(status: 200, url: self.endpoint))
        }

        await assertThrows(.insecureEndpoint) {
            _ = try await client.sendChanges(
                sampleChanges(),
                batchID: UUID(),
                to: URL(string: "http://health.example.org/v1/records")!,
                authorization: self.authorization
            )
        }
        await assertThrows(.insecureEndpoint) {
            _ = try await client.testConnection(
                to: URL(string: "http://health.example.org/v1/records")!,
                authorization: self.authorization
            )
        }
    }

    func testEndpointsWithUserinfoQueryOrFragmentAreRefused() async {
        let client = HTTPDestinationClient { _ in
            XCTFail("transport must not be invoked for a rejected endpoint")
            return (Data(), self.httpResponse(status: 200, url: self.endpoint))
        }

        for raw in [
            "https://user:pass@health.example.org/v1/records",
            "https://health.example.org/v1/records?token=x",
            "https://health.example.org/v1/records#section",
        ] {
            await assertThrows(.insecureEndpoint) {
                _ = try await client.sendChanges(
                    sampleChanges(),
                    batchID: UUID(),
                    to: URL(string: raw)!,
                    authorization: self.authorization
                )
            }
        }
    }

    func testEmptyBatchIsRefusedBeforeSending() async {
        let client = HTTPDestinationClient { _ in
            XCTFail("transport must not be invoked for an empty batch")
            return (Data(), self.httpResponse(status: 200, url: self.endpoint))
        }

        await assertThrows(.emptyBatch) {
            _ = try await client.sendChanges(
                [],
                batchID: UUID(),
                to: self.endpoint,
                authorization: self.authorization
            )
        }
    }

    func testAcknowledgmentNotCoveringWholeBatchIsRejected() async {
        // The contract guarantees accepted + duplicates == batch size; a
        // receiver that acknowledges fewer records has not confirmed the
        // batch, even with HTTP 200 and a well-formed body.
        let client = HTTPDestinationClient { request in
            (
                self.httpData(#"{"status":"accepted","accepted":0,"duplicates":0}"#),
                self.httpResponse(status: 200, url: request.url!)
            )
        }

        await assertThrows(.malformedAcknowledgment) {
            _ = try await client.sendChanges(sampleChanges(), batchID: UUID(), to: self.endpoint, authorization: self.authorization)
        }
    }

    func testOverflowingChangeAcknowledgmentIsRejectedWithoutTrapping() async {
        // accepted + duplicates + superseded overflows Int; the counts decode
        // fine and must be rejected as malformed, leaving the batch
        // unconfirmed (and therefore still queued).
        let client = HTTPDestinationClient { request in
            (
                self.httpData(#"{"status":"accepted","accepted":9223372036854775807,"duplicates":1,"superseded":0,"appliedDeletions":0,"duplicateDeletions":0}"#),
                self.httpResponse(status: 200, url: request.url!)
            )
        }

        await assertThrows(.malformedAcknowledgment) {
            _ = try await client.sendChanges(
                [.upsert(self.sampleRecord())],
                batchID: UUID(),
                to: self.endpoint,
                authorization: self.authorization
            )
        }
    }

    func testOverflowingDeletionAcknowledgmentIsRejectedWithoutTrapping() async {
        let client = HTTPDestinationClient { request in
            (
                self.httpData(#"{"status":"accepted","accepted":0,"duplicates":0,"superseded":0,"appliedDeletions":9223372036854775807,"duplicateDeletions":1}"#),
                self.httpResponse(status: 200, url: request.url!)
            )
        }

        await assertThrows(.malformedAcknowledgment) {
            _ = try await client.sendChanges(
                [.delete(DeletedRecord(id: UUID(), metric: .steps, startDate: Date(), endDate: Date()))],
                batchID: UUID(),
                to: self.endpoint,
                authorization: self.authorization
            )
        }
    }

    func testTLSValidationFailureMapsDistinctly() async {
        let client = HTTPDestinationClient { _ in
            throw URLError(.serverCertificateUntrusted)
        }

        await assertThrows(.tlsValidationFailed) {
            _ = try await client.sendChanges(sampleChanges(), batchID: UUID(), to: self.endpoint, authorization: self.authorization)
        }
        await assertThrows(.tlsValidationFailed) {
            _ = try await client.testConnection(to: self.endpoint, authorization: self.authorization)
        }
    }

    func testConnectionTestRequiresOKStatusBody() async {
        let client = HTTPDestinationClient { request in
            (
                self.httpData(#"{"status":"degraded","service":"vitalroute-receiver","apiVersion":1}"#),
                self.httpResponse(status: 200, url: request.url!)
            )
        }

        await assertThrows(.malformedAcknowledgment) {
            _ = try await client.testConnection(to: self.endpoint, authorization: self.authorization)
        }
    }

    // MARK: Helpers

    private func assertThrows(
        _ expected: DestinationClientError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as DestinationClientError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }
}
