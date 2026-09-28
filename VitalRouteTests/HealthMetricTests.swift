import XCTest
@testable import VitalRoute

final class HealthMetricTests: XCTestCase {
    func testCatalogContainsTheFiftyFiveSelectableMetrics() {
        let selectable = MetricCatalog.selectableMetrics.map(\.metric.rawValue)
        XCTAssertEqual(Set(selectable), Set([
            "steps", "heartRate", "restingHeartRate", "heartRateVariability",
            "sleep", "activeEnergy", "workouts", "bloodPressure",
            "walkingHeartRateAverage", "heartRateRecoveryOneMinute", "vo2Max", "atrialFibrillationBurden",
            "oxygenSaturation", "respiratoryRate", "bodyTemperature", "bloodGlucose", "appleSleepingWristTemperature",
            "bodyMass", "bodyFatPercentage", "leanBodyMass", "bodyMassIndex", "height", "waistCircumference",
            "flightsClimbed", "distanceWalkingRunning", "distanceCycling", "distanceSwimming", "appleExerciseTime", "appleStandTime", "basalEnergyBurned",
            "runningPower", "runningSpeed", "cyclingPower", "cyclingSpeed", "cyclingCadence", "distanceWheelchair", "pushCount",
            "walkingSpeed", "walkingStepLength", "walkingAsymmetryPercentage", "walkingDoubleSupportPercentage", "stairAscentSpeed", "stairDescentSpeed", "sixMinuteWalkTestDistance", "appleWalkingSteadiness",
            "environmentalAudioExposure", "headphoneAudioExposure", "appleStandHour", "mindfulSession", "highHeartRateEvent", "lowHeartRateEvent", "irregularHeartRhythmEvent", "appleWalkingSteadinessEvent", "environmentalAudioExposureEvent", "headphoneAudioExposureEvent",
        ]))
        XCTAssertEqual(selectable.count, 55, "no duplicate selectable identifiers")
    }

    func testEveryDescriptorDeclaresAUniqueHealthKitIdentifier() {
        let identifiers = MetricCatalog.metrics.map(\.healthKitIdentifier)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }

    func testCatalogGroupsUseAllEightSectionsAndKeepHeartMetricsTogether() {
        XCTAssertEqual(Set(MetricDescriptor.Group.allCases.map(\.rawValue)), Set([
            "activity", "heart", "vitals", "mobility", "body", "sleep", "hearing", "mindfulness",
        ]))
        for metric in [HealthMetric.heartRate, .restingHeartRate, .heartRateVariability] {
            XCTAssertEqual(metric.group, .heart)
        }
        XCTAssertEqual(MetricCatalog.selectableMetrics.count, 55)
    }

    func testComponentMetricsAreNotUserSelectable() {
        for rawValue in ["bloodPressureSystolic", "bloodPressureDiastolic"] {
            let metric = try? XCTUnwrap(HealthMetric(rawValue: rawValue))
            XCTAssertNotNil(metric, "\(rawValue) should be in the catalog")
            XCTAssertFalse(metric?.descriptor.userSelectable ?? true)
        }
        XCTAssertTrue(HealthMetric(rawValue: "bloodPressure")!.descriptor.userSelectable)
    }

    func testDescriptorRecordKindsMatchExtractionPlans() {
        XCTAssertEqual(HealthMetric(rawValue: "sleep")?.descriptor.recordKind, .category)
        XCTAssertEqual(HealthMetric(rawValue: "workouts")?.descriptor.recordKind, .workout)
        for rawValue in ["steps", "heartRate", "restingHeartRate", "heartRateVariability", "activeEnergy"] {
            XCTAssertEqual(HealthMetric(rawValue: rawValue)?.descriptor.recordKind, .quantity)
        }
        XCTAssertEqual(HealthMetric(rawValue: "bloodPressure")?.descriptor.recordKind, .correlation)
    }

    func testMetricsRoundTripThroughTheirRawValue() {
        for metric in MetricCatalog.metrics.map(\.metric) {
            XCTAssertEqual(HealthMetric(rawValue: metric.rawValue), metric)
        }
    }

    func testUnknownMetricIdentifiersAreRejected() {
        XCTAssertNil(HealthMetric(rawValue: "someFutureMetric"))
        XCTAssertNil(HealthMetric(rawValue: ""))
        XCTAssertNil(HealthMetric(rawValue: "Steps"))
    }

    func testCatalogReverseLookupResolvesComponentMetrics() {
        XCTAssertEqual(
            MetricCatalog.metric(withHealthKitIdentifier: "HKQuantityTypeIdentifierBloodPressureSystolic"),
            HealthMetric(rawValue: "bloodPressureSystolic")
        )
        XCTAssertEqual(
            MetricCatalog.metric(withHealthKitIdentifier: "HKQuantityTypeIdentifierStepCount"),
            .steps
        )
        XCTAssertEqual(MetricCatalog.metric(withHealthKitIdentifier: "HKQuantityTypeIdentifierBodyMass"), HealthMetric(rawValue: "bodyMass"))
    }

    func testMetricDecodingRejectsIdentifiersOutsideTheCatalog() throws {
        let json = #""someFutureMetric""#
        XCTAssertThrowsError(try JSONDecoder().decode(HealthMetric.self, from: Data(json.utf8)))

        let known = #""heartRate""#
        XCTAssertEqual(try JSONDecoder().decode(HealthMetric.self, from: Data(known.utf8)), .heartRate)
    }

    func testMetricEncodingIsTheRawValueString() throws {
        let data = try JSONEncoder().encode(HealthMetric(rawValue: "heartRate")!)
        XCTAssertEqual(String(data: data, encoding: .utf8), #""heartRate""#)
    }
}
