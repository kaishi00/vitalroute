import XCTest
@testable import VitalRoute

final class ExportSelectionStoreTests: XCTestCase {
    private var suites: [(defaults: UserDefaults, name: String)] = []

    override func tearDown() {
        for suite in suites {
            suite.defaults.removePersistentDomain(forName: suite.name)
        }
        suites.removeAll()
        super.tearDown()
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "export-selection-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        suites.append((defaults, name))
        return defaults
    }

    @MainActor
    func testSelectionStartsEmptyByDefault() throws {
        let store = ExportSelectionStore(defaults: try makeDefaults())

        XCTAssertTrue(store.selectedMetrics.isEmpty)
        XCTAssertFalse(store.hasSelection)
        XCTAssertEqual(store.orderedSelection, [])
    }

    @MainActor
    func testTogglingPersistsInCatalogOrder() throws {
        let defaults = try makeDefaults()
        let store = ExportSelectionStore(defaults: defaults)

        store.setMetric(.sleep, selected: true)
        store.setMetric(.steps, selected: true)
        store.setMetric(.workouts, selected: true)
        store.setMetric(.workouts, selected: false)

        XCTAssertEqual(store.orderedSelection, [.steps, .sleep])
        XCTAssertEqual(
            defaults.stringArray(forKey: "export.selectedMetrics"),
            ["steps", "sleep"]
        )
    }

    @MainActor
    func testSelectionRoundTripsAcrossStoreInstances() throws {
        let defaults = try makeDefaults()
        let first = ExportSelectionStore(defaults: defaults)
        first.setMetric(.heartRate, selected: true)
        first.setMetric(.activeEnergy, selected: true)

        let second = ExportSelectionStore(defaults: defaults)

        XCTAssertEqual(second.selectedMetrics, [.heartRate, .activeEnergy])
    }

    @MainActor
    func testUnknownPersistedValuesAreDropped() throws {
        let defaults = try makeDefaults()
        defaults.set(["steps", "bloodPressureSystolic", "not-a-metric"], forKey: "export.selectedMetrics")

        let store = ExportSelectionStore(defaults: defaults)

        XCTAssertEqual(store.selectedMetrics, [.steps])
    }

    @MainActor
    func testExpandedCatalogIsFullySelectableAndGroupedWithoutEmptySections() {
        let descriptors = HealthDataView.filteredDescriptors(query: "")
        XCTAssertEqual(Set(descriptors.map(\.metric)), Set(MetricCatalog.selectableMetrics.map(\.metric)))
        XCTAssertEqual(descriptors.count, 55)

        let groups = HealthDataView.groupedDescriptors(query: "")
        XCTAssertEqual(Set(groups.keys), Set(MetricDescriptor.Group.allCases.filter { group in
            descriptors.contains { $0.group == group }
        }))
        XCTAssertTrue(groups.values.allSatisfy { !$0.isEmpty })
    }

    func testMetricSearchMatchesNamesAndDescriptionsAndOmitsEmptyGroups() {
        let byName = HealthDataView.filteredDescriptors(query: "resting heart")
        XCTAssertTrue(byName.contains { $0.metric.rawValue == "restingHeartRate" })

        let byDescription = HealthDataView.filteredDescriptors(query: "sleep stages")
        XCTAssertTrue(byDescription.contains { $0.metric.rawValue == "sleep" })

        let grouped = HealthDataView.groupedDescriptors(query: "sleep stages")
        XCTAssertEqual(Set(grouped.keys), [.sleep])
    }

    func testMetricSearchFindsCommonAbbreviationsAndRawIDs() {
        let expectedIDs = [
            "vo2": "vo2Max",
            "hrv": "heartRateVariability",
            "bmi": "bodyMassIndex",
            "spo2": "oxygenSaturation",
            "bpm": "heartRate",
            "heartRateVariability": "heartRateVariability",
        ]

        for (query, expectedID) in expectedIDs {
            XCTAssertTrue(
                HealthDataView.filteredDescriptors(query: query).contains { $0.metric.rawValue == expectedID },
                "Expected search for \(query) to find \(expectedID)"
            )
        }
    }

    func testToggleAccessibilityIncludesCountOnlyForSelectedMetrics() {
        let date = Date(timeIntervalSince1970: 1_735_689_600)
        let latestStepRecord = HealthRecord(
            metric: .steps,
            startDate: date,
            endDate: date,
            data: .quantity(QuantityData(value: 120, unit: "count"))
        )
        let selectedLabel = HealthDataView.accessibleMetricLabel(
            for: .steps,
            latestRecord: latestStepRecord,
            sampleCount: 3,
            emptyDescription: "No recent samples shown; refresh to check",
            isSelected: true
        )
        let unselectedLabel = HealthDataView.accessibleMetricLabel(
            for: .steps,
            latestRecord: nil,
            sampleCount: 0,
            emptyDescription: "Not selected for export",
            isSelected: false
        )
        let selectedZeroLabel = HealthDataView.accessibleMetricLabel(
            for: .steps,
            latestRecord: nil,
            sampleCount: 0,
            emptyDescription: "No recent samples shown; refresh to check",
            isSelected: true
        )

        XCTAssertTrue(selectedLabel.contains("3 samples"))
        XCTAssertTrue(selectedLabel.contains("Selected for export"))
        XCTAssertFalse(unselectedLabel.contains("samples"))
        XCTAssertTrue(unselectedLabel.contains("Not selected for export"))
        XCTAssertEqual(unselectedLabel.components(separatedBy: "Not selected for export").count - 1, 1)
        XCTAssertFalse(selectedZeroLabel.contains("0 samples"))
        XCTAssertTrue(selectedZeroLabel.contains("Selected for export"))
    }

    func testRecentRecordPresentationImmediatelyFiltersDeselectedMetrics() {
        let date = Date(timeIntervalSince1970: 1_735_689_600)
        let steps = HealthRecord(
            metric: .steps, startDate: date, endDate: date,
            data: .quantity(QuantityData(value: 120, unit: "count"))
        )
        let sleep = HealthRecord(
            metric: .sleep, startDate: date, endDate: date,
            data: .category(CategoryData(value: 1, name: "asleep"))
        )
        let records = [steps, sleep]

        XCTAssertEqual(
            HealthDataView.recordsForSelectedMetrics(records, selectedMetrics: [.steps]),
            [steps]
        )
        XCTAssertTrue(
            HealthDataView.recordsForSelectedMetrics(records, selectedMetrics: []).isEmpty
        )
    }

    @MainActor
    func testLegacySelectionsSurviveAndNewMetricsStartOff() throws {
        let defaults = try makeDefaults()
        defaults.set(["steps", "heartRate", "sleep", "activeEnergy", "workouts", "restingHeartRate", "heartRateVariability"], forKey: "export.selectedMetrics")

        let store = ExportSelectionStore(defaults: defaults)
        let legacy = Set([HealthMetric.steps, .heartRate, .sleep, .activeEnergy, .workouts, .restingHeartRate, .heartRateVariability])
        XCTAssertEqual(store.selectedMetrics, legacy)
        let mindfulSession = try XCTUnwrap(HealthMetric(rawValue: "mindfulSession"))
        XCTAssertFalse(store.selectedMetrics.contains(mindfulSession))
        XCTAssertTrue(MetricCatalog.selectableMetrics.contains { $0.metric.rawValue == "bloodPressure" })
        let bloodPressureDescription = try XCTUnwrap(MetricCatalog.descriptor(for: .bloodPressure)?.shortDescription)
        XCTAssertTrue(bloodPressureDescription.contains("Paired systolic/diastolic"))
        XCTAssertTrue(bloodPressureDescription.contains("Background updates are unverified"))
        XCTAssertTrue(bloodPressureDescription.contains("reopen the app or use Sync Now"))
        XCTAssertFalse(try XCTUnwrap(MetricCatalog.descriptor(for: .bloodPressureSystolic)).userSelectable)
        XCTAssertFalse(try XCTUnwrap(MetricCatalog.descriptor(for: .bloodPressureDiastolic)).userSelectable)
    }

    @MainActor
    func testNewMetricSelectionCodableRoundTrip() throws {
        let defaults = try makeDefaults()
        let metric = try XCTUnwrap(HealthMetric(rawValue: "mindfulSession"))
        let first = ExportSelectionStore(defaults: defaults)
        first.setMetric(metric, selected: true)
        let encoded = try JSONEncoder().encode(first.selectedMetrics)
        let decoded = try JSONDecoder().decode(Set<HealthMetric>.self, from: encoded)

        XCTAssertEqual(decoded, [metric])
        XCTAssertEqual(ExportSelectionStore(defaults: defaults).selectedMetrics, [metric])
    }
}
