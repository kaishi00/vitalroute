import XCTest
@testable import VitalRoute

/// Pins the client-side mirror of the receiver's structural limits
/// (`server/validation.py`). A record that fails `isTransmittable` would be
/// rejected atomically with its whole batch, poisoning every retry, so the
/// capture and manual paths skip-and-surface instead of queueing it.
final class RecordWireLimitsTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_735_689_600)

    private func record(
        metadata: [String: String] = [:],
        sourceName: String? = nil,
        data: RecordData = .quantity(QuantityData(value: 1, unit: "count"))
    ) -> HealthRecord {
        HealthRecord(
            metric: .heartRate,
            startDate: date,
            endDate: date,
            sourceName: sourceName,
            metadata: metadata,
            data: data
        )
    }

    func testWellFormedRecordsPass() {
        XCTAssertTrue(RecordWireLimits.isTransmittable(record()))
        XCTAssertTrue(RecordWireLimits.isTransmittable(record(
            metadata: ["context": "resting"], sourceName: "Apple Watch"
        )))
    }

    func testMetadataLimitsMirrorTheReceiver() {
        XCTAssertTrue(RecordWireLimits.isTransmittable(record(
            metadata: ["k": String(repeating: "v", count: 512)]
        )))
        XCTAssertFalse(RecordWireLimits.isTransmittable(record(
            metadata: ["k": String(repeating: "v", count: 513)]
        )))
        XCTAssertFalse(RecordWireLimits.isTransmittable(record(
            metadata: [String(repeating: "k", count: 65): "v"]
        )))
        let oversized = (1...33).map { "key\($0)" }
        XCTAssertFalse(RecordWireLimits.isTransmittable(record(
            metadata: Dictionary(uniqueKeysWithValues: oversized.map { ($0, "v") })
        )))
    }

    func testNonFiniteAndNegativeValuesAreRejected() {
        XCTAssertFalse(RecordWireLimits.isTransmittable(record(
            data: .quantity(QuantityData(value: .infinity, unit: "count"))
        )))
        XCTAssertFalse(RecordWireLimits.isTransmittable(record(
            data: .workout(WorkoutData(
                activityType: "running",
                activityTypeRawValue: 52,
                duration: -1,
                totalEnergyKilocalories: nil,
                totalDistanceMeters: nil
            ))
        )))
    }

    func testCorrelationComponentBounds() {
        func correlation(_ count: Int) -> RecordData {
            .correlation(CorrelationData(components: (0..<count).map { index in
                CorrelationComponent(metric: "component\(index)", value: 1, unit: "mmHg")
            }))
        }
        XCTAssertTrue(RecordWireLimits.isTransmittable(record(data: correlation(8))))
        XCTAssertFalse(RecordWireLimits.isTransmittable(record(data: correlation(9))))
    }

    func testSeriesBounds() {
        func series(points: Int, channels: [String] = ["t", "v"]) -> RecordData {
            .series(SeriesData(
                seriesType: "electrocardiogramVoltage",
                seriesID: UUID(),
                parentID: nil,
                chunkIndex: 0,
                channels: channels,
                points: (0..<points).map { [Double($0), 1] }
            ))
        }
        XCTAssertTrue(RecordWireLimits.isTransmittable(record(data: series(points: 2048))))
        XCTAssertFalse(RecordWireLimits.isTransmittable(record(data: series(points: 2049))))
        XCTAssertFalse(RecordWireLimits.isTransmittable(record(data: series(points: 0))))
        XCTAssertFalse(RecordWireLimits.isTransmittable(record(data: series(
            points: 2,
            channels: (0...16).map { "c\($0)" }
        ))))
    }

    func testClinicalFHIRBudgets() {
        func clinical(_ resource: FHIRJSON) -> RecordData {
            .clinical(ClinicalData(fhirType: "Condition", fhirIdentifier: nil, fhirResource: resource))
        }
        XCTAssertTrue(RecordWireLimits.isTransmittable(record(data: clinical(
            .object(["resourceType": .string("Condition")])
        ))))

        var wide: [String: FHIRJSON] = [:]
        for index in 0..<4096 {
            wide["k\(index)"] = .string("v")
        }
        XCTAssertFalse(RecordWireLimits.isTransmittable(record(data: clinical(
            .object(wide)
        ))))

        var deep: [String: FHIRJSON] = ["leaf": .int(1)]
        for _ in 0..<(FHIRWireBudget.maxDepth + 2) {
            deep = ["n": .object(deep)]
        }
        XCTAssertFalse(RecordWireLimits.isTransmittable(record(data: clinical(
            .object(deep)
        ))))
    }

    func testEncodedDataOverOneMiBIsRejected() {
        // The receiver caps canonical data_json at 1 MiB; the mirror must
        // catch the same records or its batch is poisoned server-side.
        let big = ClinicalData(
            fhirType: "DocumentReference",
            fhirIdentifier: nil,
            fhirResource: .object(["text": .string(String(repeating: "x", count: 1_048_576))])
        )
        XCTAssertFalse(RecordWireLimits.isTransmittable(record(data: .clinical(big))))
    }

    func testIdentifiersAreASCIIStrict() {
        // The server pattern is ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ —
        // non-ASCII letters pass Unicode checks but not the contract.
        XCTAssertFalse(RecordWireLimits.isASCIIIdentifier("héllo", maxLength: 64))
        XCTAssertFalse(RecordWireLimits.isASCIIIdentifier("has space", maxLength: 64))
        XCTAssertFalse(RecordWireLimits.isASCIIIdentifier("-leading", maxLength: 64))
        XCTAssertTrue(RecordWireLimits.isASCIIIdentifier("bloodPressureSystolic", maxLength: 64))
        XCTAssertTrue(RecordWireLimits.isASCIIIdentifier("t", maxLength: 32))
        XCTAssertFalse(RecordWireLimits.isASCIIIdentifier("bad channel", maxLength: 32))
    }

    func testCategoryValueUpperBoundMirrorsInt32() {
        XCTAssertFalse(RecordWireLimits.isTransmittable(record(
            data: .category(CategoryData(value: Int(Int32.max) + 1, name: nil))
        )))
    }

    func testChangeEventFilterAlwaysAdmitsDeletions() {
        let deletion = SyncChangeEvent.delete(DeletedRecord(
            id: UUID(), metric: .steps, startDate: date, endDate: date
        ))
        XCTAssertTrue(RecordWireLimits.isTransmittableChangeEvent(deletion))
        let poison = SyncChangeEvent.upsert(record(
            metadata: ["k": String(repeating: "v", count: 600)]
        ))
        XCTAssertFalse(RecordWireLimits.isTransmittableChangeEvent(poison))
    }
}
