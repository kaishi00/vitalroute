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

    private func samplePayload() -> SyncPayload {
        SyncPayload(records: [
            HealthRecord(
                metric: .steps,
                value: 100,
                unit: "count",
                startDate: Date(timeIntervalSince1970: 1_735_689_600),
                endDate: Date(timeIntervalSince1970: 1_735_689_600)
            )
        ])
    }

    // MARK: Request construction

    func testSendBuildsContractRequest() async throws {
        var captured: URLRequest?
        let client = HTTPDestinationClient { request in
            captured = request
            return (
                self.httpData(#"{"status":"accepted","accepted":1,"duplicates":0}"#),
                self.httpResponse(status: 200, url: request.url!)
            )
        }

        let acknowledgment = try await client.send(
            samplePayload(),
            to: endpoint,
            authorization: authorization
        )

        XCTAssertEqual(acknowledgment, SyncAcknowledgment(accepted: 1, duplicates: 0))
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token-0123456789")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        // The body is a contract payload the receiver accepts.
        let decoded = try SyncPayloadEncoder.decode(body)
        XCTAssertEqual(decoded.records.count, 1)
        XCTAssertEqual(decoded.records.first?.metric, .steps)
    }

    func testTestConnectionSendsGETWithNoBody() async throws {
        var captured: URLRequest?
        let client = HTTPDestinationClient { request in
            captured = request
            return (
                self.httpData(#"{"status":"ok","service":"vitalroute-receiver","apiVersion":1}"#),
                self.httpResponse(status: 200, url: request.url!)
            )
        }

        let response = try await client.testConnection(to: endpoint, authorization: authorization)

        XCTAssertEqual(response, ReceiverHealthResponse(status: "ok", service: "vitalroute-receiver", apiVersion: 1))
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.httpBodyStream)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token-0123456789")
    }

    // MARK: Acknowledgment validation

    func testValidAcknowledgmentDecodes() async throws {
        let client = HTTPDestinationClient { request in
            (
                self.httpData(#"{"status":"accepted","accepted":12,"duplicates":3,"schemaVersion":1}"#),
                self.httpResponse(status: 200, url: request.url!)
            )
        }

        // Acknowledgment counts must cover the whole batch; send 15 records
        // to match the 12 new + 3 duplicates the receiver reports.
        let records = (0..<15).map { index in
            HealthRecord(
                metric: .steps,
                value: Double(index),
                unit: "count",
                startDate: Date(timeIntervalSince1970: 1_735_689_600),
                endDate: Date(timeIntervalSince1970: 1_735_689_600)
            )
        }
        let acknowledgment = try await client.send(
            SyncPayload(records: records),
            to: endpoint,
            authorization: authorization
        )

        XCTAssertEqual(acknowledgment.accepted, 12)
        XCTAssertEqual(acknowledgment.duplicates, 3)
        XCTAssertEqual(acknowledgment.delivered, 15)
    }

    func testWrongAcknowledgmentStatusIsMalformed() async {
        let client = HTTPDestinationClient { request in
            (
                self.httpData(#"{"status":"queued","accepted":1,"duplicates":0}"#),
                self.httpResponse(status: 200, url: request.url!)
            )
        }

        await assertThrows(.malformedAcknowledgment) {
            try await client.send(samplePayload(), to: self.endpoint, authorization: self.authorization)
        }
    }

    func testMissingAcknowledgmentCountsAreMalformed() async {
        let client = HTTPDestinationClient { request in
            (self.httpData(#"{"status":"accepted"}"#), self.httpResponse(status: 200, url: request.url!))
        }

        await assertThrows(.malformedAcknowledgment) {
            try await client.send(samplePayload(), to: self.endpoint, authorization: self.authorization)
        }
    }

    func testNonJSONAcknowledgmentIsMalformed() async {
        let client = HTTPDestinationClient { request in
            (self.httpData("<html>ok</html>"), self.httpResponse(status: 200, url: request.url!))
        }

        await assertThrows(.malformedAcknowledgment) {
            try await client.send(samplePayload(), to: self.endpoint, authorization: self.authorization)
        }
    }

    func testEmptyAcknowledgmentBodyIsMalformed() async {
        let client = HTTPDestinationClient { request in
            (Data(), self.httpResponse(status: 200, url: request.url!))
        }

        await assertThrows(.malformedAcknowledgment) {
            try await client.send(samplePayload(), to: self.endpoint, authorization: self.authorization)
        }
    }

    // MARK: Status mapping

    func testUnauthorizedAndForbiddenMapToAuthenticationFailure() async {
        for status in [401, 403] {
            let client = HTTPDestinationClient { request in
                (Data(), self.httpResponse(status: status, url: request.url!))
            }
            await assertThrows(.authenticationFailed) {
                try await client.send(samplePayload(), to: self.endpoint, authorization: self.authorization)
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
            try await client.send(samplePayload(), to: self.endpoint, authorization: self.authorization)
        }
        await assertThrows(.redirected) {
            try await client.testConnection(to: self.endpoint, authorization: self.authorization)
        }
    }

    func testPayloadTooLargeMaps() async {
        let client = HTTPDestinationClient { request in
            (Data(), self.httpResponse(status: 413, url: request.url!))
        }

        await assertThrows(.payloadTooLarge) {
            try await client.send(samplePayload(), to: self.endpoint, authorization: self.authorization)
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
            try await client.send(samplePayload(), to: self.endpoint, authorization: self.authorization)
        }
    }

    // MARK: Transport error mapping

    func testURLErrorTimeoutMaps() async {
        let client = HTTPDestinationClient { _ in
            throw URLError(.timedOut)
        }

        await assertThrows(.requestTimedOut) {
            try await client.send(samplePayload(), to: self.endpoint, authorization: self.authorization)
        }
    }

    func testURLErrorCannotConnectMaps() async {
        let client = HTTPDestinationClient { _ in
            throw URLError(.cannotConnectToHost)
        }

        await assertThrows(.connectionFailed) {
            try await client.send(samplePayload(), to: self.endpoint, authorization: self.authorization)
        }
    }

    func testNonHTTPResponseIsInvalid() async {
        let client = HTTPDestinationClient { request in
            (Data(), URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        }

        await assertThrows(.invalidResponse) {
            try await client.send(samplePayload(), to: self.endpoint, authorization: self.authorization)
        }
    }

    func testCancelledURLErrorSurfacesAsCancellation() async {
        let client = HTTPDestinationClient { _ in
            throw URLError(.cancelled)
        }

        do {
            _ = try await client.send(samplePayload(), to: endpoint, authorization: authorization)
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
            try await client.send(
                samplePayload(),
                to: URL(string: "http://health.example.org/v1/records")!,
                authorization: self.authorization
            )
        }
        await assertThrows(.insecureEndpoint) {
            try await client.testConnection(
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
                try await client.send(
                    samplePayload(),
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
            try await client.send(
                SyncPayload(records: []),
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
            try await client.send(samplePayload(), to: self.endpoint, authorization: self.authorization)
        }
    }

    func testTLSValidationFailureMapsDistinctly() async {
        let client = HTTPDestinationClient { _ in
            throw URLError(.serverCertificateUntrusted)
        }

        await assertThrows(.tlsValidationFailed) {
            try await client.send(samplePayload(), to: self.endpoint, authorization: self.authorization)
        }
        await assertThrows(.tlsValidationFailed) {
            try await client.testConnection(to: self.endpoint, authorization: self.authorization)
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
            try await client.testConnection(to: self.endpoint, authorization: self.authorization)
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
