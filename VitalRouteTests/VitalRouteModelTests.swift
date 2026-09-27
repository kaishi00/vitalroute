import XCTest
@testable import VitalRoute

final class VitalRouteModelTests: XCTestCase {
    @MainActor
    func testSuccessfulEmptyQueryIsDistinguishedFromNotLoaded() async {
        let provider = StubHealthDataProvider(records: [])
        let model = VitalRouteModel(healthData: provider)

        await model.requestAccessAndLoadRecentData(metrics: [.steps])

        XCTAssertTrue(model.authorizationRequestCompleted)
        XCTAssertTrue(model.hasSuccessfulHealthQuery)
        XCTAssertTrue(model.recentRecords.isEmpty)
        XCTAssertNil(model.healthDataError)
    }

    @MainActor
    func testFailedQueryDoesNotReportSuccessfulEmptyResult() async {
        let provider = StubHealthDataProvider(records: [], shouldFailQuery: true)
        let model = VitalRouteModel(healthData: provider)

        await model.requestAccessAndLoadRecentData(metrics: [.steps])

        XCTAssertTrue(model.authorizationRequestCompleted)
        XCTAssertFalse(model.hasSuccessfulHealthQuery)
        XCTAssertTrue(model.recentRecords.isEmpty)
        XCTAssertNotNil(model.healthDataError)
    }

    @MainActor
    func testFailedRefreshClearsPreviouslyLoadedRecords() async {
        let record = HealthRecord(
            metric: .steps,
            startDate: Date(timeIntervalSince1970: 1_735_689_600),
            endDate: Date(timeIntervalSince1970: 1_735_689_600),
            data: .quantity(QuantityData(value: 42, unit: "count"))
        )
        let provider = StubHealthDataProvider(records: [record])
        let model = VitalRouteModel(healthData: provider)

        await model.requestAccessAndLoadRecentData(metrics: [.steps])
        XCTAssertEqual(model.recentRecords, [record])
        XCTAssertTrue(model.hasSuccessfulHealthQuery)

        provider.shouldFailQuery = true
        await model.requestAccessAndLoadRecentData(metrics: [.steps])

        XCTAssertTrue(model.recentRecords.isEmpty)
        XCTAssertFalse(model.hasSuccessfulHealthQuery)
        XCTAssertNotNil(model.healthDataError)
    }

    @MainActor
    func testAuthorizationFailureDoesNotMarkRequestCompleteOrQuery() async {
        let provider = StubHealthDataProvider(records: [], shouldFailAuthorization: true)
        let model = VitalRouteModel(healthData: provider)

        await model.requestAccessAndLoadRecentData(metrics: [.steps])

        XCTAssertFalse(model.authorizationRequestCompleted)
        XCTAssertFalse(model.hasSuccessfulHealthQuery)
        XCTAssertEqual(provider.queryCount, 0)
        XCTAssertNotNil(model.healthDataError)
    }

    @MainActor
    func testEmptyMetricSetSurfacesGuidanceInsteadOfRequestingNothing() async {
        let provider = StubHealthDataProvider(records: [])
        let model = VitalRouteModel(healthData: provider)

        await model.requestAccessAndLoadRecentData(metrics: [])

        XCTAssertFalse(model.authorizationRequestCompleted)
        XCTAssertEqual(provider.authorizationRequestedMetrics, [])
        XCTAssertEqual(provider.queryCount, 0)
        XCTAssertEqual(
            model.healthDataError,
            "Select at least one category in Health Data, then review access."
        )
    }

    @MainActor
    func testAuthorizationScopeFollowsSelection() async {
        let provider = StubHealthDataProvider(records: [])
        let model = VitalRouteModel(healthData: provider)

        await model.requestAccessAndLoadRecentData(metrics: [.sleep, .steps])

        XCTAssertEqual(provider.authorizationRequestedMetrics, [.sleep, .steps])
        XCTAssertEqual(provider.queriedMetrics, [.sleep, .steps])
    }
}

@MainActor
private final class StubHealthDataProvider: HealthDataProviding {
    let records: [HealthRecord]
    var shouldFailQuery: Bool
    let shouldFailAuthorization: Bool
    private(set) var queryCount = 0
    private(set) var authorizationRequestedMetrics: [HealthMetric] = []
    private(set) var queriedMetrics: [HealthMetric] = []

    init(
        records: [HealthRecord],
        shouldFailQuery: Bool = false,
        shouldFailAuthorization: Bool = false
    ) {
        self.records = records
        self.shouldFailQuery = shouldFailQuery
        self.shouldFailAuthorization = shouldFailAuthorization
    }

    var isAvailable: Bool { true }

    func requestReadAuthorization(for metrics: Set<HealthMetric>) async throws {
        authorizationRequestedMetrics.append(contentsOf: metrics.sorted { $0.rawValue < $1.rawValue })
        if shouldFailAuthorization {
            throw StubHealthDataError.authorizationFailed
        }
    }

    func queryRecentRecords(
        since startDate: Date,
        metrics: Set<HealthMetric>,
        perMetricLimit: Int
    ) async throws -> [HealthRecord] {
        queryCount += 1
        queriedMetrics.append(contentsOf: metrics.sorted { $0.rawValue < $1.rawValue })
        if shouldFailQuery {
            throw StubHealthDataError.queryFailed
        }
        return records.filter { metrics.contains($0.metric) }
    }

    func exportPage(
        for metric: HealthMetric,
        since anchorData: Data?,
        windowStart: Date,
        limit: Int
    ) async throws -> HealthExportPage {
        HealthExportPage(records: [], anchorData: anchorData, isFull: false)
    }

    func changePage(
        for metric: HealthMetric,
        since anchorData: Data?,
        windowStart: Date,
        limit: Int
    ) async throws -> HealthChangePage {
        HealthChangePage(
            additions: records.filter { $0.metric == metric },
            deletions: [],
            anchorData: anchorData,
            isFull: false
        )
    }

    private(set) var observedMetrics: [Set<HealthMetric>] = []
    private(set) var observationStopCount = 0
    private var observerHandler: (@Sendable (ObserverCompletion) -> Void)?


    func latestRecords(
        for metric: HealthMetric,
        windowStart: Date,
        limit: Int
    ) async throws -> [HealthRecord] {
        []
    }

    func observeChanges(
        for metrics: Set<HealthMetric>,
        handler: @escaping @Sendable (ObserverCompletion) -> Void
    ) async throws {
        observedMetrics.append(metrics)
        observerHandler = handler
    }

    func stopObservingChanges() async {
        observationStopCount += 1
        observerHandler = nil
    }

    func fireObserver() {
        observerHandler?(ObserverCompletion {})
    }
}

private enum StubHealthDataError: LocalizedError {
    case queryFailed
    case authorizationFailed

    var errorDescription: String? {
        switch self {
        case .queryFailed:
            "The test query failed."
        case .authorizationFailed:
            "The test authorization request failed."
        }
    }
}
