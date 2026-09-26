import XCTest
@testable import VitalRoute

/// Coding and wire-contract tests for the typed record model and the v3
/// change-batch encoder.
final class RecordModelTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_735_689_600)

    private func record(
        metric: HealthMetric = .heartRate,
        data: RecordData,
        id: UUID = UUID()
    ) -> HealthRecord {
        HealthRecord(
            id: id,
            metric: metric,
            startDate: date,
            endDate: date,
            sourceName: "Apple Watch",
            deviceName: "Apple Watch",
            metadata: ["context": "resting"],
            data: data
        )
    }

    // MARK: Deterministic encoding

    /// The shared JSON encoder: sorted keys, ISO 8601 with milliseconds.
    private func encode(_ value: some Encodable) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func decodeRecord(_ data: Data) throws -> HealthRecord {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = formatter.date(from: raw) ?? plain.date(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO 8601 date string."
                )
            }
            return date
        }
        return try decoder.decode(HealthRecord.self, from: data)
    }

    // MARK: Every kind round-trips with its discriminator

    func testQuantityRecordRoundTrips() throws {
        let original = record(data: .quantity(QuantityData(value: 72, unit: "count/min")))

        let encoded = try encode(original)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["metric"] as? String, "heartRate")
        XCTAssertEqual(json["kind"] as? String, "quantity")
        let payload = try XCTUnwrap(json["data"] as? [String: Any])
        XCTAssertEqual(payload["type"] as? String, "quantity")
        XCTAssertEqual(payload["value"] as? Double, 72)
        XCTAssertEqual(payload["unit"] as? String, "count/min")

        let decoded = try decodeRecord(encoded)
        XCTAssertEqual(decoded, original)
    }

    func testCategoryRecordRoundTrips() throws {
        let original = record(metric: .sleep, data: .category(CategoryData(value: 5, name: "asleepREM")))

        let encoded = try encode(original)
        let decoded = try decodeRecord(encoded)
        XCTAssertEqual(decoded, original)
        guard case .category(let payload) = decoded.data else {
            return XCTFail("expected category payload")
        }
        XCTAssertEqual(payload.value, 5)
        XCTAssertEqual(payload.name, "asleepREM")
    }

    func testCorrelationRecordRoundTrips() throws {
        let original = record(
            metric: .bloodPressure,
            data: .correlation(CorrelationData(components: [
                CorrelationComponent(metric: "bloodPressureSystolic", value: 122, unit: "mmHg"),
                CorrelationComponent(metric: "bloodPressureDiastolic", value: 78, unit: "mmHg"),
            ]))
        )

        let encoded = try encode(original)
        XCTAssertEqual(original.kind, .correlation)
        let decoded = try decodeRecord(encoded)
        XCTAssertEqual(decoded, original)
    }

    func testWorkoutRecordRoundTrips() throws {
        let original = record(
            metric: .workouts,
            data: .workout(WorkoutData(
                activityType: "running",
                activityTypeRawValue: 52,
                duration: 1920,
                totalEnergyKilocalories: 331.2,
                totalDistanceMeters: 5210.5
            ))
        )

        let decoded = try decodeRecord(try encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testActivitySummaryRecordRoundTrips() throws {
        let original = record(
            data: .activitySummary(ActivitySummaryData(
                activeEnergyBurnedKilocalories: 501,
                exerciseTimeMinutes: 32,
                dateComponentsUTC: "2026-09-25"
            ))
        )

        let encoded = try encode(original)
        let decoded = try decodeRecord(encoded)
        XCTAssertEqual(decoded, original)
        guard case .activitySummary(let payload) = decoded.data else {
            return XCTFail("expected activitySummary payload")
        }
        XCTAssertEqual(payload.dateComponentsUTC, "2026-09-25")
    }

    func testSeriesRecordRoundTripsAndCarriesParent() throws {
        let seriesID = UUID()
        let parentID = UUID()
        let original = HealthRecord(
            id: HealthKitRecordMapper.deterministicChunkID(seriesID: seriesID, chunkIndex: 0),
            metric: .heartRate,
            startDate: date,
            endDate: date,
            data: .series(SeriesData(
                seriesType: "electrocardiogramVoltage",
                seriesID: seriesID,
                parentID: parentID,
                chunkIndex: 0,
                channels: ["t", "microvolts"],
                points: [[0.0, -12.5], [0.001953125, 8.25]]
            ))
        )

        let encoded = try encode(original)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["kind"] as? String, "series")
        let payload = try XCTUnwrap(json["data"] as? [String: Any])
        XCTAssertEqual(payload["seriesType"] as? String, "electrocardiogramVoltage")
        // The receiver normalizes UUID spellings case-insensitively; the
        // encoder's own spelling is what round-trips here.
        XCTAssertEqual(payload["parentID"] as? String, parentID.uuidString)

        let decoded = try decodeRecord(encoded)
        XCTAssertEqual(decoded, original)
    }

    func testElectrocardiogramRecordRoundTrips() throws {
        let ecgID = UUID()
        let original = HealthRecord(
            id: ecgID,
            metric: .heartRate,
            startDate: date,
            endDate: date.addingTimeInterval(30),
            data: .electrocardiogram(ElectrocardiogramData(
                classification: "sinusRhythm",
                classificationRawValue: 2,
                symptomStatus: "none",
                symptomStatusRawValue: 1,
                averageHeartRate: 62,
                samplingFrequency: 512,
                voltageSeriesID: ecgID,
                voltageChunkCount: 3
            ))
        )

        let decoded = try decodeRecord(try encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testClinicalRecordRoundTripsWithStructuredFHIR() throws {
        let original = record(
            metric: .heartRate,
            data: .clinical(ClinicalData(
                fhirType: "Condition",
                fhirIdentifier: "example-1",
                fhirResource: .object([
                    "resourceType": .string("Condition"),
                    "code": .object(["text": .string("Example")]),
                    "clinicalStatus": .object([
                        "coding": .array([.object(["code": .string("active")])]),
                    ]),
                    "verificationStatus": .bool(true),
                    "onsetAge": .int(42),
                    "abatementDecimal": .double(1.5),
                    "note": .array([.object(["text": .string("n")])]),
                ])
            ))
        )

        let encoded = try encode(original)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let payload = try XCTUnwrap(json["data"] as? [String: Any])
        XCTAssertEqual(payload["type"] as? String, "clinical")
        // The FHIR resource is preserved structurally on the wire — a JSON
        // object, never a stringified blob.
        let resource = try XCTUnwrap(payload["fhirResource"] as? [String: Any])
        XCTAssertEqual(resource["resourceType"] as? String, "Condition")

        let decoded = try decodeRecord(encoded)
        XCTAssertEqual(decoded, original)
    }

    func testFHIRValueRoundTripsScalarCases() throws {
        for value in [FHIRJSON.null, .bool(true), .int(-3), .double(2.5), .string("hi")] {
            let data = try JSONEncoder().encode(Wrap(value: value))
            let decoded = try JSONDecoder().decode(Wrap.self, from: data)
            XCTAssertEqual(decoded.value, value)
        }
    }

    private struct Wrap: Codable, Equatable {
        let value: FHIRJSON
    }

    // MARK: Malformed payloads fail loudly

    func testUnknownDataTypeIsRejected() throws {
        let json = """
        {"id":"\(UUID().uuidString)","metric":"heartRate","kind":"quantity",
         "startDate":"2025-01-01T00:00:00.000Z","endDate":"2025-01-01T00:00:00.000Z",
         "metadata":{},"data":{"type":"telepathy","value":1,"unit":"count"}}
        """
        XCTAssertThrowsError(try decodeRecord(Data(json.utf8)))
    }

    func testDataTypeNotMatchingKindIsRejected() throws {
        let json = """
        {"id":"\(UUID().uuidString)","metric":"heartRate","kind":"category",
         "startDate":"2025-01-01T00:00:00.000Z","endDate":"2025-01-01T00:00:00.000Z",
         "metadata":{},"data":{"type":"quantity","value":1,"unit":"count"}}
        """
        XCTAssertThrowsError(try decodeRecord(Data(json.utf8)))
    }

    func testPayloadWithWrongFieldsIsRejected() throws {
        let json = """
        {"id":"\(UUID().uuidString)","metric":"heartRate","kind":"quantity",
         "startDate":"2025-01-01T00:00:00.000Z","endDate":"2025-01-01T00:00:00.000Z",
         "metadata":{},"data":{"type":"quantity","value":1}}
        """
        XCTAssertThrowsError(try decodeRecord(Data(json.utf8)))
    }

    func testUnknownMetricIsRejectedClientSide() throws {
        // The client owns the catalog: an identifier it does not define
        // cannot be decoded, while the receiver accepts any well-formed one.
        let json = """
        {"id":"\(UUID().uuidString)","metric":"someFutureMetric","kind":"quantity",
         "startDate":"2025-01-01T00:00:00.000Z","endDate":"2025-01-01T00:00:00.000Z",
         "metadata":{},"data":{"type":"quantity","value":1,"unit":"count"}}
        """
        XCTAssertThrowsError(try decodeRecord(Data(json.utf8)))
    }

    func testNonFiniteQuantityValueFailsEncoding() {
        let record = record(data: .quantity(QuantityData(value: .nan, unit: "count")))
        XCTAssertThrowsError(try encode(record))
    }

    // MARK: Fractional-second timestamps (unchanged contract behavior)

    func testFractionalSecondTimestampsSurviveRoundTrip() throws {
        let startDate = Date(timeIntervalSince1970: 1_735_689_600.25)
        let endDate = Date(timeIntervalSince1970: 1_735_689_630.75)
        let original = HealthRecord(
            metric: .heartRate,
            startDate: startDate,
            endDate: endDate,
            data: .quantity(QuantityData(value: 72, unit: "count/min"))
        )

        let encoded = try encode(original)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let encodedStartDate = try XCTUnwrap(json["startDate"] as? String)
        XCTAssertTrue(encodedStartDate.contains(".25"), "expected fractional seconds in \(encodedStartDate)")

        let decoded = try decodeRecord(encoded)
        XCTAssertEqual(decoded.startDate, startDate)
        XCTAssertEqual(decoded.endDate, endDate)
    }

    func testSubMillisecondDigitsAreTruncatedByDesign() throws {
        let exact = Date(timeIntervalSince1970: 1_735_689_600.123)
        let input = Date(timeIntervalSince1970: 1_735_689_600.123456)
        let original = HealthRecord(
            metric: .steps,
            startDate: input,
            endDate: input,
            data: .quantity(QuantityData(value: 42, unit: "count"))
        )

        let decoded = try decodeRecord(try encode(original))
        XCTAssertEqual(decoded.startDate, exact)
    }

    func testDecodingAcceptsWholeSecondISO8601Strings() throws {
        let original = HealthRecord(
            metric: .steps,
            startDate: date,
            endDate: date,
            data: .quantity(QuantityData(value: 42, unit: "count"))
        )
        var encoded = try encode(original)
        // Swap the millisecond spelling for whole seconds, which the
        // contract also accepts on decode.
        let text = String(data: encoded, encoding: .utf8)!
            .replacingOccurrences(of: "2025-01-01T00:00:00.000Z", with: "2025-01-01T00:00:00Z")
        encoded = Data(text.utf8)

        let decoded = try decodeRecord(encoded)
        XCTAssertEqual(decoded.startDate, date)
    }

    // MARK: Change batch encoding

    func testChangeBatchEncodesContractV3Shape() throws {
        let batchID = UUID()
        let createdAt = date
        let record = HealthRecord(
            id: UUID(),
            metric: .steps,
            startDate: date,
            endDate: date,
            data: .quantity(QuantityData(value: 8000, unit: "count"))
        )
        let changes: [SyncChangeEvent] = [
            .upsert(record),
            .delete(DeletedRecord(id: UUID(), metric: .steps, startDate: date, endDate: date)),
        ]

        let data = try ChangeBatchEncoder.encode(batchID: batchID, createdAt: createdAt, changes: changes)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 3)
        XCTAssertEqual(json["batchId"] as? String, batchID.uuidString.lowercased())
        XCTAssertNotNil(json["createdAt"] as? String)
        let encodedChanges = try XCTUnwrap(json["changes"] as? [[String: Any]])
        XCTAssertEqual(encodedChanges.count, 2)
        XCTAssertEqual(encodedChanges.first?["kind"] as? String, "upsert")
        XCTAssertEqual(encodedChanges.last?["kind"] as? String, "delete")
        let encodedRecord = try XCTUnwrap(encodedChanges.first?["record"] as? [String: Any])
        XCTAssertEqual(encodedRecord["metric"] as? String, "steps")
        XCTAssertEqual(encodedRecord["kind"] as? String, "quantity")
    }

    func testChangeBatchEncodingIsDeterministic() throws {
        let record = HealthRecord(
            metric: .steps,
            startDate: date,
            endDate: date,
            data: .quantity(QuantityData(value: 8000, unit: "count"))
        )
        let changes: [SyncChangeEvent] = [.upsert(record)]
        let batchID = UUID()

        let first = try ChangeBatchEncoder.encode(batchID: batchID, createdAt: date, changes: changes)
        let second = try ChangeBatchEncoder.encode(batchID: batchID, createdAt: date, changes: changes)
        XCTAssertEqual(first, second)
    }

    // MARK: Acknowledgment reconciliation

    private func acknowledgment(
        accepted: Int,
        duplicates: Int,
        superseded: Int,
        appliedDeletions: Int,
        duplicateDeletions: Int,
        cascadedDeletions: Int = 0
    ) -> ChangeAcknowledgment {
        ChangeAcknowledgment(
            accepted: accepted,
            duplicates: duplicates,
            superseded: superseded,
            appliedDeletions: appliedDeletions,
            duplicateDeletions: duplicateDeletions,
            cascadedDeletions: cascadedDeletions
        )
    }

    func testReconcilesAcceptsCountsThatCoverTheBatch() {
        let ack = acknowledgment(
            accepted: 2, duplicates: 1, superseded: 1, appliedDeletions: 1, duplicateDeletions: 0
        )

        XCTAssertTrue(ack.reconciles(upsertsSent: 4, deletesSent: 1))
        XCTAssertFalse(ack.reconciles(upsertsSent: 5, deletesSent: 1))
        XCTAssertFalse(ack.reconciles(upsertsSent: 4, deletesSent: 2))
    }

    func testCascadedDeletionsNeverCountTowardReconciliation() {
        // The receiver deletes series chunks as a consequence of the parent
        // delete; the client sent only the parent, so the extra count must
        // not break reconciliation.
        let ack = acknowledgment(
            accepted: 0, duplicates: 0, superseded: 0,
            appliedDeletions: 1, duplicateDeletions: 0,
            cascadedDeletions: 3
        )

        XCTAssertTrue(ack.reconciles(upsertsSent: 0, deletesSent: 1))
    }

    func testReconcilesRejectsOverflowingUpsertTotal() {
        // Every count is receiver-controlled. `Int.max + 1` cannot match any
        // real batch, and it must fail reconciliation rather than trap.
        let ack = acknowledgment(
            accepted: .max, duplicates: 1, superseded: 0, appliedDeletions: 0, duplicateDeletions: 0
        )

        XCTAssertFalse(ack.reconciles(upsertsSent: 1, deletesSent: 0))
    }

    func testReconcilesRejectsOverflowingDeletionTotal() {
        let ack = acknowledgment(
            accepted: 0, duplicates: 0, superseded: 0, appliedDeletions: .max, duplicateDeletions: 1
        )

        XCTAssertFalse(ack.reconciles(upsertsSent: 0, deletesSent: 1))
    }

    func testReconcilesRejectsCountsOverflowingAcrossAllThreeUpsertTerms() {
        let ack = acknowledgment(
            accepted: .max, duplicates: .max, superseded: 1, appliedDeletions: 0, duplicateDeletions: 0
        )

        XCTAssertNil(ChangeAcknowledgment.checkedSum([ack.accepted, ack.duplicates, ack.superseded]))
        XCTAssertFalse(ack.reconciles(upsertsSent: 0, deletesSent: 0))
    }

    func testAcknowledgmentDecodingAcceptsReceiversWithoutCascadeCounts() throws {
        let body = #"{"status":"accepted","accepted":1,"duplicates":0,"superseded":0,"appliedDeletions":0,"duplicateDeletions":0}"#
        let ack = try ChangeAcknowledgmentDecoder.decode(Data(body.utf8))
        XCTAssertEqual(ack.cascadedDeletions, 0)
    }

    func testAcknowledgmentDecodingRejectsBadStatusAndNegativeCounts() {
        for body in [
            #"{"status":"queued","accepted":1,"duplicates":0,"superseded":0,"appliedDeletions":0,"duplicateDeletions":0}"#,
            #"{"status":"accepted","accepted":-1,"duplicates":0,"superseded":0,"appliedDeletions":0,"duplicateDeletions":0}"#,
            #"{"status":"accepted","accepted":1,"duplicates":0,"superseded":0,"appliedDeletions":0,"duplicateDeletions":0,"cascadedDeletions":-2}"#,
        ] {
            XCTAssertThrowsError(try ChangeAcknowledgmentDecoder.decode(Data(body.utf8)))
        }
    }
}
