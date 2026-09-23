import HealthKit
import XCTest
@testable import VitalRoute

final class HealthKitRecordMapperTests: XCTestCase {
    func testEveryMetricMapsToItsHealthKitSampleType() throws {
        for metric in HealthMetric.allCases {
            let sampleType = try XCTUnwrap(HealthKitRecordMapper.sampleType(for: metric))
            XCTAssertEqual(sampleType.identifier, metric.healthKitIdentifier)
        }
    }

    func testConvertsQuantitySamplesToExpectedValuesAndUnits() throws {
        let date = Date(timeIntervalSince1970: 1_735_689_600)
        let cases: [(HealthMetric, HKQuantityTypeIdentifier, HKUnit, Double, String)] = [
            (.steps, .stepCount, .count(), 1200, "count"),
            (.heartRate, .heartRate, HKUnit.count().unitDivided(by: .minute()), 72, "count/min"),
            (.restingHeartRate, .restingHeartRate, HKUnit.count().unitDivided(by: .minute()), 58, "count/min"),
            (.heartRateVariability, .heartRateVariabilitySDNN, HKUnit.secondUnit(with: .milli), 35, "ms"),
            (.activeEnergy, .activeEnergyBurned, .kilocalorie(), 245, "kcal")
        ]

        for (metric, identifier, unit, value, expectedUnit) in cases {
            let type = try XCTUnwrap(HKObjectType.quantityType(forIdentifier: identifier))
            let sample = HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: unit, doubleValue: value),
                start: date,
                end: date
            )
            let record = try XCTUnwrap(HealthKitRecordMapper.makeRecord(from: sample, metric: metric))

            XCTAssertEqual(record.metric, metric)
            XCTAssertEqual(record.value, value, accuracy: 0.001)
            XCTAssertEqual(record.unit, expectedUnit)
        }
    }

    func testConvertsSleepSampleDurationAndStage() throws {
        let date = Date(timeIntervalSince1970: 1_735_689_600)
        let type = try XCTUnwrap(HKObjectType.categoryType(forIdentifier: .sleepAnalysis))
        let sample = HKCategorySample(
            type: type,
            value: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            start: date,
            end: date.addingTimeInterval(90 * 60)
        )

        let record = try XCTUnwrap(HealthKitRecordMapper.makeRecord(from: sample, metric: .sleep))

        XCTAssertEqual(record.value, 90 * 60, accuracy: 0.001)
        XCTAssertEqual(record.unit, "s")
        XCTAssertEqual(record.metadata["sleepStage"], "asleepCore")
    }

    func testPreservesWorkoutMetadata() throws {
        let date = Date(timeIntervalSince1970: 1_735_689_600)
        let workout = Self.makeWorkout(
            activityType: .running,
            start: date,
            duration: 30 * 60,
            energyKcal: 210,
            distanceMeters: 5_000
        )

        let record = try XCTUnwrap(HealthKitRecordMapper.makeRecord(from: workout, metric: .workouts))

        XCTAssertEqual(record.value, 30 * 60, accuracy: 0.001)
        XCTAssertEqual(record.unit, "s")
        XCTAssertEqual(record.metadata["activityTypeCode"], String(HKWorkoutActivityType.running.rawValue))
        XCTAssertEqual(record.metadata["activeEnergyKcal"], "210.0")
        XCTAssertEqual(record.metadata["distanceMeters"], "5000.0")
    }

    func testPreservesWorkoutDistanceForNonWalkingActivities() throws {
        let date = Date(timeIntervalSince1970: 1_735_689_600)
        let workout = Self.makeWorkout(
            activityType: .cycling,
            start: date,
            duration: 45 * 60,
            energyKcal: 300,
            distanceMeters: 15_000
        )

        let record = try XCTUnwrap(HealthKitRecordMapper.makeRecord(from: workout, metric: .workouts))

        XCTAssertEqual(record.metadata["distanceMeters"], "15000.0")
        XCTAssertEqual(record.metadata["activeEnergyKcal"], "300.0")
    }

    func testReturnsNilForMismatchedSampleType() throws {
        let date = Date(timeIntervalSince1970: 1_735_689_600)
        let type = try XCTUnwrap(HKObjectType.quantityType(forIdentifier: .stepCount))
        let sample = HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: .count(), doubleValue: 42),
            start: date,
            end: date
        )

        XCTAssertNil(HealthKitRecordMapper.makeRecord(from: sample, metric: .sleep))
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
