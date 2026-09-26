import XCTest
@testable import VitalRoute

final class SyncPayloadTests: XCTestCase {
    func testPayloadRoundTripsHealthRecordAsISO8601JSON() throws {
        let date = Date(timeIntervalSince1970: 1_735_689_600)
        let record = HealthRecord(
            id: UUID(),
            metric: .heartRate,
            value: 72,
            unit: "count/min",
            startDate: date,
            endDate: date,
            sourceName: "Apple Watch",
            deviceName: "Apple Watch",
            metadata: ["context": "resting"]
        )
        let payload = SyncPayload(createdAt: date, records: [record])

        let data = try SyncPayloadEncoder.encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        let encodedRecords = try XCTUnwrap(json["records"] as? [[String: Any]])
        XCTAssertEqual(encodedRecords.first?["metric"] as? String, "heartRate")
        XCTAssertEqual(encodedRecords.first?["unit"] as? String, "count/min")
        XCTAssertEqual(encodedRecords.first?["sourceName"] as? String, "Apple Watch")
        XCTAssertNotNil(encodedRecords.first?["startDate"] as? String)

        let decoded = try SyncPayloadEncoder.decode(data)
        XCTAssertEqual(decoded, payload)
    }

    func testFractionalSecondTimestampsSurviveRoundTrip() throws {
        let startDate = Date(timeIntervalSince1970: 1_735_689_600.25)
        let endDate = Date(timeIntervalSince1970: 1_735_689_630.75)
        let record = HealthRecord(
            metric: .heartRate,
            value: 72,
            unit: "count/min",
            startDate: startDate,
            endDate: endDate
        )
        let payload = SyncPayload(createdAt: endDate, records: [record])

        let data = try SyncPayloadEncoder.encode(payload)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedRecords = try XCTUnwrap(json["records"] as? [[String: Any]])
        let encodedStartDate = try XCTUnwrap(encodedRecords.first?["startDate"] as? String)
        XCTAssertTrue(encodedStartDate.contains(".25"), "expected fractional seconds in \(encodedStartDate)")

        let decoded = try SyncPayloadEncoder.decode(data)
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.records.first?.startDate, startDate)
        XCTAssertEqual(decoded.records.first?.endDate, endDate)
    }

    func testSubMillisecondDigitsAreTruncatedByDesign() throws {
        let exact = Date(timeIntervalSince1970: 1_735_689_600.123)
        let input = Date(timeIntervalSince1970: 1_735_689_600.123456)
        let record = HealthRecord(
            metric: .steps,
            value: 42,
            unit: "count",
            startDate: input,
            endDate: input
        )
        let payload = SyncPayload(createdAt: input, records: [record])

        let decoded = try SyncPayloadEncoder.decode(try SyncPayloadEncoder.encode(payload))

        XCTAssertEqual(decoded.records.first?.startDate, exact)
    }

    func testDecodingAcceptsWholeSecondISO8601Strings() throws {
        let wholeSecond = #"{"createdAt":"2025-01-01T00:00:00Z","records":[],"schemaVersion":1}"#
        let data = try XCTUnwrap(wholeSecond.data(using: .utf8))

        let decoded = try SyncPayloadEncoder.decode(data)

        XCTAssertEqual(decoded.createdAt, Date(timeIntervalSince1970: 1_735_689_600))
    }

    func testDecodingAcceptsTimezoneOffsetISO8601Strings() throws {
        let offsetForm = #"{"createdAt":"2025-01-01T02:00:00.500+02:00","records":[],"schemaVersion":1}"#
        let data = try XCTUnwrap(offsetForm.data(using: .utf8))

        let decoded = try SyncPayloadEncoder.decode(data)

        XCTAssertEqual(decoded.createdAt, Date(timeIntervalSince1970: 1_735_689_600.5))
    }

    // MARK: Acknowledgment reconciliation

    func testReconcilesAcceptsCountsThatCoverTheBatch() {
        let acknowledgment = ChangeAcknowledgment(
            accepted: 2, duplicates: 1, superseded: 1, appliedDeletions: 1, duplicateDeletions: 0
        )

        XCTAssertTrue(acknowledgment.reconciles(upsertsSent: 4, deletesSent: 1))
        XCTAssertFalse(acknowledgment.reconciles(upsertsSent: 5, deletesSent: 1))
        XCTAssertFalse(acknowledgment.reconciles(upsertsSent: 4, deletesSent: 2))
    }

    func testReconcilesRejectsOverflowingUpsertTotal() {
        // Every count is receiver-controlled. `Int.max + 1` cannot match any
        // real batch, and it must fail reconciliation rather than trap.
        let acknowledgment = ChangeAcknowledgment(
            accepted: .max, duplicates: 1, superseded: 0, appliedDeletions: 0, duplicateDeletions: 0
        )

        XCTAssertFalse(acknowledgment.reconciles(upsertsSent: 1, deletesSent: 0))
    }

    func testReconcilesRejectsOverflowingDeletionTotal() {
        let acknowledgment = ChangeAcknowledgment(
            accepted: 0, duplicates: 0, superseded: 0, appliedDeletions: .max, duplicateDeletions: 1
        )

        XCTAssertFalse(acknowledgment.reconciles(upsertsSent: 0, deletesSent: 1))
    }

    func testReconcilesRejectsCountsOverflowingAcrossAllThreeUpsertTerms() {
        let acknowledgment = ChangeAcknowledgment(
            accepted: .max, duplicates: .max, superseded: 1, appliedDeletions: 0, duplicateDeletions: 0
        )

        XCTAssertNil(ChangeAcknowledgment.checkedSum([acknowledgment.accepted, acknowledgment.duplicates, acknowledgment.superseded]))
        XCTAssertFalse(acknowledgment.reconciles(upsertsSent: 0, deletesSent: 0))
    }

    func testV1AcknowledgmentDeliveryTotalIsNilWhenCountsOverflow() {
        let acknowledgment = SyncAcknowledgment(accepted: .max, duplicates: 1)

        XCTAssertNil(acknowledgment.delivered, "a hostile ack must not trap the client")
    }

    func testDecodingRejectsMalformedDateStrings() throws {
        let malformed = #"{"createdAt":"not-a-date","records":[],"schemaVersion":1}"#
        let data = try XCTUnwrap(malformed.data(using: .utf8))

        XCTAssertThrowsError(try SyncPayloadEncoder.decode(data)) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }
}
