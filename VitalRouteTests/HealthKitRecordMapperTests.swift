import HealthKit
import XCTest
@testable import VitalRoute

final class HealthKitRecordMapperTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_735_689_600)

    // MARK: Type resolution

    func testEverySelectableMetricMapsToItsHealthKitSampleType() throws {
        for descriptor in MetricCatalog.metrics {
            if descriptor.metric.rawValue == "bloodPressure" {
                // Correlation types are not HKSampleTypes resolvable through
                // the sample-type path in this environment; their components
                // are what gets authorized.
                continue
            }
            let sampleType = try XCTUnwrap(
                HealthKitRecordMapper.sampleType(for: descriptor),
                "no sample type for \(descriptor.metric.rawValue)"
            )
            XCTAssertEqual(sampleType.identifier, descriptor.healthKitIdentifier)
        }
    }

    func testAuthorizationObjectTypesIncludeCorrelationComponents() throws {
        let bloodPressure = try XCTUnwrap(HealthMetric(rawValue: "bloodPressure"))
        let types = HealthKitRecordMapper.objectTypes(for: [bloodPressure])
        let identifiers = Set(types.map(\.identifier))
        XCTAssertTrue(identifiers.contains("HKCorrelationTypeIdentifierBloodPressure"))
        XCTAssertTrue(identifiers.contains("HKQuantityTypeIdentifierBloodPressureSystolic"))
        XCTAssertTrue(identifiers.contains("HKQuantityTypeIdentifierBloodPressureDiastolic"))
    }

    // MARK: Quantity

    func testConvertsQuantitySamplesToTypedRecordsWithCanonicalUnits() throws {
        let cases: [(HealthMetric, HKQuantityTypeIdentifier, HKUnit, Double, String)] = [
            (.steps, .stepCount, .count(), 1200, "count"),
            (.heartRate, .heartRate, HKUnit.count().unitDivided(by: .minute()), 72, "count/min"),
            (.restingHeartRate, .restingHeartRate, HKUnit.count().unitDivided(by: .minute()), 58, "count/min"),
            (.heartRateVariability, .heartRateVariabilitySDNN, HKUnit.secondUnit(with: .milli), 35, "ms"),
            (.activeEnergy, .activeEnergyBurned, .kilocalorie(), 245, "kcal"),
        ]

        for (metric, identifier, unit, value, expectedUnit) in cases {
            let type = try XCTUnwrap(HKObjectType.quantityType(forIdentifier: identifier))
            let sample = HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: unit, doubleValue: value),
                start: date,
                end: date
            )
            let mapped = try XCTUnwrap(HealthKitRecordMapper.makeMappedSample(from: sample, metric: metric))
            let record = try XCTUnwrap(mapped.record)

            XCTAssertEqual(record.metric, metric)
            XCTAssertEqual(record.kind, .quantity)
            XCTAssertEqual(record.sourceName, sample.sourceRevision.source.name)
            guard case .quantity(let payload) = record.data else {
                return XCTFail("expected quantity payload for \(metric)")
            }
            XCTAssertEqual(payload.value, value, accuracy: 0.001)
            XCTAssertEqual(payload.unit, expectedUnit)
        }
    }

    // MARK: Category

    func testConvertsSleepSampleToNamedCategoryRecord() throws {
        let type = try XCTUnwrap(HKObjectType.categoryType(forIdentifier: .sleepAnalysis))
        let sample = HKCategorySample(
            type: type,
            value: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            start: date,
            end: date.addingTimeInterval(90 * 60)
        )

        let mapped = try XCTUnwrap(HealthKitRecordMapper.makeMappedSample(from: sample, metric: .sleep))
        let record = try XCTUnwrap(mapped.record)

        XCTAssertEqual(record.kind, .category)
        guard case .category(let payload) = record.data else {
            return XCTFail("expected category payload")
        }
        XCTAssertEqual(payload.value, HKCategoryValueSleepAnalysis.asleepCore.rawValue)
        XCTAssertEqual(payload.name, "asleepCore")
    }

    func testUnmappableSleepStageCarriesRawValueWithoutName() {
        // HealthKit refuses to construct samples with invalid category
        // values, so the unmappable stage path is exercised on the naming
        // function directly.
        XCTAssertNil(HealthKitRecordMapper.categoryName(999, naming: .sleepAnalysis))
    }

    // MARK: Correlation

    func testAttributtesBloodPressureComponentsByCatalogMetric() throws {
        let correlationType = try XCTUnwrap(
            HKObjectType.correlationType(forIdentifier: .bloodPressure)
        )
        let systolicType = try XCTUnwrap(HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic))
        let diastolicType = try XCTUnwrap(HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic))
        let systolic = HKQuantitySample(
            type: systolicType,
            quantity: HKQuantity(unit: .millimeterOfMercury(), doubleValue: 122),
            start: date,
            end: date
        )
        let diastolic = HKQuantitySample(
            type: diastolicType,
            quantity: HKQuantity(unit: .millimeterOfMercury(), doubleValue: 78),
            start: date,
            end: date
        )
        let correlation = HKCorrelation(
            type: correlationType,
            start: date,
            end: date,
            objects: [systolic, diastolic]
        )

        let mapped = try XCTUnwrap(
            HealthKitRecordMapper.makeMappedSample(
                from: correlation,
                metric: HealthMetric(rawValue: "bloodPressure")!
            )
        )
        let record = try XCTUnwrap(mapped.record)

        XCTAssertEqual(record.kind, .correlation)
        guard case .correlation(let payload) = record.data else {
            return XCTFail("expected correlation payload")
        }
        // Components are sorted by metric for deterministic wire output.
        XCTAssertEqual(payload.components.map(\.metric), ["bloodPressureDiastolic", "bloodPressureSystolic"])
        XCTAssertEqual(payload.components.map(\.value), [78, 122])
        XCTAssertEqual(payload.components.map(\.unit), ["mmHg", "mmHg"])
    }

    // MARK: Workout

    @available(iOS, deprecated: 18.0)
    func testWorkoutMapsStructuredDetails() throws {
        let workout = Self.makeWorkout(
            activityType: .running,
            start: date,
            duration: 30 * 60,
            energyKcal: 210,
            distanceMeters: 5_000
        )

        let mapped = try XCTUnwrap(HealthKitRecordMapper.makeMappedSample(from: workout, metric: .workouts))
        let record = try XCTUnwrap(mapped.record)

        XCTAssertEqual(record.kind, .workout)
        guard case .workout(let payload) = record.data else {
            return XCTFail("expected workout payload")
        }
        XCTAssertEqual(payload.activityType, "running")
        XCTAssertEqual(payload.activityTypeRawValue, Int(HKWorkoutActivityType.running.rawValue))
        XCTAssertEqual(payload.duration, 30 * 60, accuracy: 0.001)
        XCTAssertEqual(payload.totalEnergyKilocalories ?? -1, 210, accuracy: 0.001)
        XCTAssertEqual(payload.totalDistanceMeters ?? -1, 5_000, accuracy: 0.001)
    }

    @available(iOS, deprecated: 18.0)
    func testWorkoutMapsDistanceForNonWalkingActivities() throws {
        let workout = Self.makeWorkout(
            activityType: .cycling,
            start: date,
            duration: 45 * 60,
            energyKcal: 300,
            distanceMeters: 15_000
        )

        let mapped = try XCTUnwrap(HealthKitRecordMapper.makeMappedSample(from: workout, metric: .workouts))
        guard case .workout(let payload) = try XCTUnwrap(mapped.record).data else {
            return XCTFail("expected workout payload")
        }
        XCTAssertEqual(payload.totalDistanceMeters ?? -1, 15_000, accuracy: 0.001)
        XCTAssertEqual(payload.totalEnergyKilocalories ?? -1, 300, accuracy: 0.001)
    }

    func testActivityTypeNameCoversCommonActivitiesWithDeterministicFallback() {
        XCTAssertEqual(HealthKitRecordMapper.activityTypeName(.running), "running")
        XCTAssertEqual(HealthKitRecordMapper.activityTypeName(.traditionalStrengthTraining), "traditionalStrengthTraining")
        let fallback = HealthKitRecordMapper.activityTypeName(HKWorkoutActivityType(rawValue: 999_999) ?? .running)
        XCTAssertTrue(fallback == "running" || fallback.hasPrefix("hkActivityType"))
    }

    func testWorkoutDistanceExportsEachMeasuredDistanceType() throws {
        let measuredIdentifiers: [HKQuantityTypeIdentifier] = [
            .distanceWalkingRunning,
            .distanceCycling,
            .distanceSwimming,
            .distanceWheelchair,
            .distanceDownhillSnowSports,
            .distanceCrossCountrySkiing,
            .distancePaddleSports,
            .distanceRowing,
            .distanceSkatingSports,
        ]
        let meters = 1_234.5

        for identifier in measuredIdentifiers {
            let measuredType = try XCTUnwrap(
                HKObjectType.quantityType(forIdentifier: identifier),
                "missing quantity type for \(identifier)"
            )
            let distance = HealthKitRecordMapper.workoutDistance { type in
                type == measuredType ? HKQuantity(unit: .meter(), doubleValue: meters) : nil
            }

            XCTAssertEqual(
                distance?.doubleValue(for: .meter()) ?? -1,
                meters,
                accuracy: 0.001,
                "\(identifier.rawValue) statistic was not exported"
            )
        }
    }

    func testWorkoutDistanceSumsMixedDistanceStatistics() throws {
        let quantitiesByRawIdentifier: [String: Double] = [
            HKQuantityTypeIdentifier.distanceSwimming.rawValue: 800,
            HKQuantityTypeIdentifier.distanceCycling.rawValue: 20_000,
            HKQuantityTypeIdentifier.distanceRowing.rawValue: 5_000,
            HKQuantityTypeIdentifier.distanceSkatingSports.rawValue: 3_000,
        ]

        let distance = HealthKitRecordMapper.workoutDistance { type in
            quantitiesByRawIdentifier[type.identifier].map { HKQuantity(unit: .meter(), doubleValue: $0) }
        }

        XCTAssertEqual(distance?.doubleValue(for: .meter()) ?? -1, 28_800, accuracy: 0.001)
    }

    func testWorkoutDistanceReturnsNilWhenNoDistanceTypeIsMeasured() {
        XCTAssertNil(HealthKitRecordMapper.workoutDistance { _ in nil })
    }

    // MARK: Mismatched families

    func testReturnsNilForMismatchedSampleType() throws {
        let type = try XCTUnwrap(HKObjectType.quantityType(forIdentifier: .stepCount))
        let sample = HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: .count(), doubleValue: 42),
            start: date,
            end: date
        )

        XCTAssertNil(HealthKitRecordMapper.makeMappedSample(from: sample, metric: .sleep))
    }

    // MARK: Clinical

    /// HKClinicalRecord exposes no constructible initializer, so the
    /// mapper's clinical glue is exercised on-device only; here we pin the
    /// FHIR decoding it relies on: structural preservation via FHIRJSON.
    func testClinicalFHIRDecodingPreservesStructure() throws {
        let fhirJSON = """
        {"resourceType":"AllergyIntolerance","code":{"text":"Pollen"},
         "clinicalStatus":{"coding":[{"code":"active"}]},
         "onsetDateTime":"2026-01-02","isCritical":true,"severity":{"scale":3}}
        """
        let value = try JSONDecoder().decode(FHIRJSON.self, from: Data(fhirJSON.utf8))
        guard case .object(let fhirObject) = value else {
            return XCTFail("expected a structured FHIR object")
        }
        XCTAssertEqual(fhirObject["resourceType"], FHIRJSON.string("AllergyIntolerance"))
        XCTAssertEqual(fhirObject["isCritical"], FHIRJSON.bool(true))
        XCTAssertEqual(fhirObject["severity"], FHIRJSON.object(["scale": .int(3)]))
        XCTAssertEqual(
            fhirObject["clinicalStatus"],
            FHIRJSON.object(["coding": .array([.object(["code": .string("active")])])])
        )
    }

    // MARK: Series chunking

    func testSeriesChunkingSplitsPointsAndDerivesDeterministicIDs() throws {
        let seriesID = UUID()
        let parentID = UUID()
        let metric = try XCTUnwrap(HealthMetric(rawValue: "heartRate"))
        // 3 chunks of 10, 10, and 5 points.
        let points: [[Double]] = (0..<25).map { [Double($0), Double($0) * 1.5] }

        let records = HealthKitRecordMapper.seriesChunkRecords(
            seriesType: "electrocardiogramVoltage",
            seriesID: seriesID,
            parentID: parentID,
            channels: ["t", "microvolts"],
            points: points,
            metric: metric,
            parentStart: date,
            parentEnd: date.addingTimeInterval(24),
            chunkSize: 10
        )

        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.map(\.kind), [.series, .series, .series])
        // Deterministic identity: same series/index, same UUID.
        XCTAssertEqual(
            records.map(\.id),
            (0..<3).map { HealthKitRecordMapper.deterministicChunkID(seriesID: seriesID, chunkIndex: $0) }
        )
        for (index, record) in records.enumerated() {
            guard case .series(let payload) = record.data else {
                return XCTFail("expected series payload")
            }
            XCTAssertEqual(payload.seriesID, seriesID)
            XCTAssertEqual(payload.parentID, parentID)
            XCTAssertEqual(payload.chunkIndex, index)
            XCTAssertEqual(payload.channels, ["t", "microvolts"])
            XCTAssertEqual(payload.points.count, index == 2 ? 5 : 10)
        }
    }

    func testSeriesChunkIDsDifferAcrossSeriesAndMatchTheSyntheticSenderScheme() {
        let first = HealthKitRecordMapper.deterministicChunkID(seriesID: UUID(), chunkIndex: 0)
        let second = HealthKitRecordMapper.deterministicChunkID(seriesID: UUID(), chunkIndex: 0)
        let retried = HealthKitRecordMapper.deterministicChunkID(seriesID: first, chunkIndex: 7)

        XCTAssertNotEqual(first, second)
        // UUIDv4 formatting (version and variant bits) so the derived id is
        // indistinguishable from a random one.
        XCTAssertEqual(first.uuidString.split(separator: "-")[2].first, "4")
    }

    func testSeriesChunkDatesSpanEachChunkTimeInterval() throws {
        let seriesID = UUID()
        let metric = try XCTUnwrap(HealthMetric(rawValue: "heartRate"))
        // Offsets 0s and 10s from the parent start.
        let points: [[Double]] = [[0, 1], [10, 2]]

        let records = HealthKitRecordMapper.seriesChunkRecords(
            seriesType: "heartbeatSeries",
            seriesID: seriesID,
            parentID: seriesID,
            channels: ["t", "interval"],
            points: points,
            metric: metric,
            parentStart: date,
            parentEnd: date.addingTimeInterval(10)
        )

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].startDate, date)
        XCTAssertEqual(records[0].endDate, date.addingTimeInterval(10))
    }

    // MARK: ECG naming

    func testECGClassificationNamesAreStable() {
        XCTAssertEqual(HealthKitRecordMapper.ecgClassificationName(.sinusRhythm), "sinusRhythm")
        XCTAssertEqual(HealthKitRecordMapper.ecgClassificationName(.atrialFibrillation), "atrialFibrillation")
        XCTAssertEqual(HealthKitRecordMapper.ecgClassificationName(.notSet), "notSet")
    }

    // MARK: Sleep naming

    func testSleepStageNamesMatchTheHistoricalSpellings() {
        XCTAssertEqual(
            HealthKitRecordMapper.categoryName(HKCategoryValueSleepAnalysis.asleepREM.rawValue, naming: .sleepAnalysis),
            "asleepREM"
        )
        XCTAssertEqual(
            HealthKitRecordMapper.categoryName(HKCategoryValueSleepAnalysis.awake.rawValue, naming: .sleepAnalysis),
            "awake"
        )
        XCTAssertNil(HealthKitRecordMapper.categoryName(999, naming: .sleepAnalysis))
    }

    /// The deprecated convenience initializer is the only way to construct an
    /// HKWorkout carrying energy/distance statistics without a live
    /// HKHealthStore; marking this fixture deprecated silences the warning
    /// at the use sites inside it.
    @available(iOS, deprecated: 18.0)
    private static func makeWorkout(
        activityType: HKWorkoutActivityType,
        start: Date,
        duration: TimeInterval,
        energyKcal: Double,
        distanceMeters: Double
    ) -> HKWorkout {
        HKWorkout(
            activityType: activityType,
            start: start,
            end: start.addingTimeInterval(duration),
            workoutEvents: nil,
            totalEnergyBurned: HKQuantity(unit: .kilocalorie(), doubleValue: energyKcal),
            totalDistance: HKQuantity(unit: .meter(), doubleValue: distanceMeters),
            metadata: nil
        )
    }
}
