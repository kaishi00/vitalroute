import XCTest
@testable import VitalRoute

final class HealthMetricTests: XCTestCase {
    func testInitialReadSetContainsSevenSupportedMetrics() {
        XCTAssertEqual(HealthMetric.allCases.count, 7)
        XCTAssertEqual(Set(HealthMetric.allCases), Set([
            .steps, .heartRate, .restingHeartRate, .heartRateVariability,
            .sleep, .activeEnergy, .workouts
        ]))
    }

    func testMapsHealthKitTypeIdentifiersToMetrics() {
        XCTAssertEqual(HealthMetric(healthKitIdentifier: "HKQuantityTypeIdentifierStepCount"), .steps)
        XCTAssertEqual(HealthMetric(healthKitIdentifier: "HKQuantityTypeIdentifierHeartRate"), .heartRate)
        XCTAssertEqual(HealthMetric(healthKitIdentifier: "HKQuantityTypeIdentifierRestingHeartRate"), .restingHeartRate)
        XCTAssertEqual(HealthMetric(healthKitIdentifier: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"), .heartRateVariability)
        XCTAssertEqual(HealthMetric(healthKitIdentifier: "HKCategoryTypeIdentifierSleepAnalysis"), .sleep)
        XCTAssertEqual(HealthMetric(healthKitIdentifier: "HKQuantityTypeIdentifierActiveEnergyBurned"), .activeEnergy)
        XCTAssertEqual(HealthMetric(healthKitIdentifier: "HKWorkoutTypeIdentifier"), .workouts)
        XCTAssertNil(HealthMetric(healthKitIdentifier: "HKQuantityTypeIdentifierBodyMass"))
    }
}
