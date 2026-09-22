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

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SyncPayload.self, from: data)
        XCTAssertEqual(decoded, payload)
    }
}
