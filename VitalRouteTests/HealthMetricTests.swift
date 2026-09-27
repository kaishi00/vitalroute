import XCTest
@testable import VitalRoute

final class HealthMetricTests: XCTestCase {
    func testCatalogContainsTheSevenSelectableMetrics() {
        let selectable = MetricCatalog.selectableMetrics.map(\.metric.rawValue)
        XCTAssertEqual(Set(selectable), Set([
            "steps", "heartRate", "restingHeartRate", "heartRateVariability",
            "sleep", "activeEnergy", "workouts",
        ]))
        XCTAssertEqual(selectable.count, 7, "no duplicate selectable identifiers")
    }

    func testEveryDescriptorDeclaresAUniqueHealthKitIdentifier() {
        let identifiers = MetricCatalog.metrics.map(\.healthKitIdentifier)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }

    func testComponentMetricsAreNotUserSelectable() {
        for rawValue in ["bloodPressureSystolic", "bloodPressureDiastolic", "bloodPressure"] {
            let metric = try? XCTUnwrap(HealthMetric(rawValue: rawValue))
            XCTAssertNotNil(metric, "\(rawValue) should be in the catalog")
            XCTAssertFalse(metric?.descriptor.userSelectable ?? true)
        }
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
        XCTAssertNil(MetricCatalog.metric(withHealthKitIdentifier: "HKQuantityTypeIdentifierBodyMass"))
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
