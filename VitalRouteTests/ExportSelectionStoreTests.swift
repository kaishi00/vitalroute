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
        defaults.set(["steps", "bloodPressure", "not-a-metric"], forKey: "export.selectedMetrics")

        let store = ExportSelectionStore(defaults: defaults)

        XCTAssertEqual(store.selectedMetrics, [.steps])
    }
}
