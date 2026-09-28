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

    func testBloodPressureDisplayUsesSystolicThenDiastolicLabelsRegardlessOfStorageOrder() {
        let pressure = HealthRecord(
            metric: .bloodPressure,
            startDate: date,
            endDate: date,
            data: .correlation(CorrelationData(components: [
                CorrelationComponent(metric: "bloodPressureDiastolic", value: 78, unit: "mmHg"),
                CorrelationComponent(metric: "bloodPressureSystolic", value: 122, unit: "mmHg"),
            ]))
        )

        XCTAssertEqual(pressure.displayValue, "Systolic 122 mmHg · Diastolic 78 mmHg")
    }

    func testIncompleteBloodPressureCorrelationDisplaysUnavailableComponentSafely() {
        let pressure = HealthRecord(
            metric: .bloodPressure,
            startDate: date,
            endDate: date,
            data: .correlation(CorrelationData(components: [
                CorrelationComponent(metric: "bloodPressureDiastolic", value: 78, unit: "mmHg"),
            ]))
        )

        XCTAssertEqual(pressure.displayValue, "Systolic unavailable · Diastolic 78 mmHg")
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

    /// Pins the shared derivation so the Swift client and the Python
    /// synthetic sender cannot drift: SHA-256 of
    /// "series:<lowercased uuid>:<index>", first 16 bytes, v4 formatting.
    func testDeterministicChunkIDMatchesTheCrossImplementationKnownAnswer() {
        let fixed = UUID(uuidString: "6f9619ff-8b86-d011-b42d-00c04fc964ff")!
        XCTAssertEqual(
            HealthKitRecordMapper.deterministicChunkID(seriesID: fixed, chunkIndex: 0)
                .uuidString.lowercased(),
            "a9d90958-56a1-4238-9979-764a7d550194"
        )
    }

    /// JSON has one number spelling: integral doubles encode as integers
    /// and re-decode as `.int`. Contractual, not accidental (see FHIRJSON's
    /// number-fidelity note).
    func testFHIRIntegralDoubleCoercesToIntOnRoundTrip() throws {
        let encoded = try JSONEncoder().encode(Wrap(value: .double(2.0)))
        let decoded = try JSONDecoder().decode(Wrap.self, from: encoded)
        XCTAssertEqual(decoded.value, .int(2))
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

/// Display formatting must never trap: records shown on screen are not
/// wire-validated, so an extreme finite HealthKit value has to render
/// clamped instead of crashing the view with an out-of-range `Int(_:)`.
final class DisplayValueFormattingTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_735_689_600)

    private func quantityRecord(value: Double, unit: String) -> HealthRecord {
        HealthRecord(
            metric: .heartRate,
            startDate: date,
            endDate: date,
            data: .quantity(QuantityData(value: value, unit: unit))
        )
    }

    func testQuantitySecondsUseSecondsBelowOneMinuteAndMinutesAfterward() {
        for (seconds, expected) in [(0.0, "0 sec"), (30, "30 sec"), (59, "59 sec"),
                                    (60, "1 min"), (90, "1.5 min")] {
            XCTAssertEqual(quantityRecord(value: seconds, unit: "s").displayValue, expected)
        }
    }

    func testExtremeAndNonFiniteQuantitySecondsDoNotTrap() {
        for (seconds, expected) in [
            (Double.greatestFiniteMagnitude, "\(Int.max) min"),
            (1e300, "\(Int.max) min"),
            (-1e300, "0 sec"),
            (Double.nan, "0 sec"),
            (Double.infinity, "\(Int.max) min"),
            (-Double.infinity, "0 sec")
        ] {
            XCTAssertEqual(quantityRecord(value: seconds, unit: "s").displayValue, expected)
        }
    }

    func testWorkoutDurationsUseSecondsBelowOneMinuteAndMinutesAfterward() {
        for (seconds, expected) in [(0.0, "Running · 0 sec"), (30, "Running · 30 sec"),
                                    (59, "Running · 59 sec"), (60, "Running · 1 min"),
                                    (90, "Running · 1.5 min")] {
            let record = HealthRecord(
                metric: .steps,
                startDate: date,
                endDate: date,
                data: .workout(WorkoutData(
                    activityType: "running", activityTypeRawValue: 52,
                    duration: seconds, totalEnergyKilocalories: nil, totalDistanceMeters: nil
                ))
            )
            XCTAssertEqual(record.displayValue, expected)
        }
    }

    func testExtremeAndNonFiniteWorkoutDurationsDoNotTrap() {
        for (seconds, expected) in [
            (1e300, "Running · \(Int.max) min"),
            (-1e300, "Running · 0 sec"),
            (Double.nan, "Running · 0 sec"),
            (Double.infinity, "Running · \(Int.max) min"),
            (-Double.infinity, "Running · 0 sec")
        ] {
            let record = HealthRecord(
                metric: .steps,
                startDate: date,
                endDate: date,
                data: .workout(WorkoutData(
                    activityType: "running",
                    activityTypeRawValue: 52,
                    duration: seconds,
                    totalEnergyKilocalories: nil,
                    totalDistanceMeters: nil
                ))
            )
            XCTAssertEqual(record.displayValue, expected)
        }
    }

    func testExtremeFiniteExerciseMinutesDoNotTrap() {
        let record = HealthRecord(
            metric: .steps,
            startDate: date,
            endDate: date,
            data: .activitySummary(ActivitySummaryData(exerciseTimeMinutes: 1e300))
        )
        XCTAssertEqual(record.displayValue, "\(Int.max) min exercise")
    }

    func testNegativeExerciseMinutesRenderAsZero() {
        let record = HealthRecord(
            metric: .steps,
            startDate: date,
            endDate: date,
            data: .activitySummary(ActivitySummaryData(exerciseTimeMinutes: -3))
        )
        XCTAssertEqual(record.displayValue, "0 min exercise")
    }

    func testHumanizedCategoryNameKeepsAcronymsAndSplitsCamelCase() {
        XCTAssertEqual(HealthRecord.humanizedCategoryName("asleepREM"), "Asleep REM")
        XCTAssertEqual(HealthRecord.humanizedCategoryName("sinusRhythm"), "Sinus rhythm")
        XCTAssertEqual(HealthRecord.humanizedCategoryName("awake"), "Awake")
        XCTAssertEqual(HealthRecord.humanizedCategoryName("REM sleep"), "REM sleep")
        XCTAssertEqual(HealthRecord.humanizedCategoryName(""), "")
    }

    func testClampedIntCoversTheBoundaries() {
        XCTAssertEqual(HealthRecord.clampedInt(.greatestFiniteMagnitude), Int.max)
        XCTAssertEqual(HealthRecord.clampedInt(-.greatestFiniteMagnitude), Int.min)
        XCTAssertEqual(HealthRecord.clampedInt(.nan), 0)
        XCTAssertEqual(HealthRecord.clampedInt(.infinity), Int.max)
        XCTAssertEqual(HealthRecord.clampedInt(42.9), 42)
        XCTAssertEqual(HealthRecord.clampedInt(-3.5), -3)
    }
}

/// The manual delivery path and the automatic outbox path must batch by
/// the same byte budget (the shared `Outbox.deliveryBatchByteLimit`), with
/// an injectable limit so tests can exercise the boundary on either path.
final class DeliveryBatchingTests: XCTestCase {
    private func events(_ count: Int) -> [SyncChangeEvent] {
        (0..<count).map { SyncChangeEvent.upsert(HealthRecord(
            metric: .heartRate,
            startDate: Date(timeIntervalSince1970: TimeInterval(1_735_689_600 + $0)),
            endDate: Date(timeIntervalSince1970: TimeInterval(1_735_689_600 + $0)),
            data: .quantity(QuantityData(value: Double($0), unit: "count/min"))
        )) }
    }

    private func encodedSize(_ event: SyncChangeEvent) -> Int {
        (try? JSONEncoder().encode(event))?.count ?? 0
    }

    func testByteLimitSplitsBatchesBeforeTheCountLimit() {
        let batch = events(10)
        let size = encodedSize(batch[0])

        // A budget fitting exactly one event must produce one batch per
        // event, even though the count limit would allow all ten.
        let batches = batch.batchedForDelivery(maxCount: 10, byteLimit: size)
        XCTAssertEqual(batches.count, 10)
        XCTAssertTrue(batches.allSatisfy { $0.count == 1 })
    }

    func testByteLimitAdmitsEventsWhileTheyFit() {
        let batch = events(4)
        let size = encodedSize(batch[0])
        // Budget exactly two events (sizes are near-identical for these
        // records; a slightly generous budget keeps the test focused on
        // splitting, not on encoder jitter).
        let batches = batch.batchedForDelivery(maxCount: 10, byteLimit: size * 2 + 64)
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[0].count, 2)
        XCTAssertEqual(batches[1].count, 2)
    }

    func testSingleOversizedEventStillShipsAlone() {
        let batch = events(1)
        let size = encodedSize(batch[0])
        let batches = batch.batchedForDelivery(maxCount: 10, byteLimit: size - 1)
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].count, 1)
    }

    func testDefaultBudgetIsTheSharedOutboxConstant() {
        // Drift guard: the manual path's default must be exactly the
        // constant the outbox path batches by.
        let batch = events(3)
        let withDefault = batch.batchedForDelivery(maxCount: 100)
        let withExplicit = batch.batchedForDelivery(
            maxCount: 100, byteLimit: Outbox.deliveryBatchByteLimit
        )
        XCTAssertEqual(withDefault, withExplicit)
    }
}
