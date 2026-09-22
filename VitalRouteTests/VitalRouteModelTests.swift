import XCTest
@testable import VitalRoute

final class VitalRouteModelTests: XCTestCase {
    @MainActor
    func testSuccessfulEmptyQueryIsDistinguishedFromNotLoaded() async {
        let provider = StubHealthDataProvider(records: [])
        let model = VitalRouteModel(healthData: provider)

        await model.requestAccessAndLoadRecentData()

        XCTAssertTrue(model.authorizationRequestCompleted)
        XCTAssertTrue(model.hasSuccessfulHealthQuery)
        XCTAssertTrue(model.recentRecords.isEmpty)
        XCTAssertNil(model.healthDataError)
    }

    @MainActor
    func testFailedQueryDoesNotReportSuccessfulEmptyResult() async {
        let provider = StubHealthDataProvider(records: [], shouldFailQuery: true)
        let model = VitalRouteModel(healthData: provider)

        await model.requestAccessAndLoadRecentData()

        XCTAssertTrue(model.authorizationRequestCompleted)
        XCTAssertFalse(model.hasSuccessfulHealthQuery)
        XCTAssertTrue(model.recentRecords.isEmpty)
        XCTAssertNotNil(model.healthDataError)
    }

    @MainActor
    func testFailedRefreshClearsPreviouslyLoadedRecords() async {
        let record = HealthRecord(
            metric: .steps,
            value: 42,
            unit: "count",
            startDate: Date(timeIntervalSince1970: 1_735_689_600),
            endDate: Date(timeIntervalSince1970: 1_735_689_600)
        )
        let provider = StubHealthDataProvider(records: [record])
        let model = VitalRouteModel(healthData: provider)

        await model.requestAccessAndLoadRecentData()
        XCTAssertEqual(model.recentRecords, [record])
        XCTAssertTrue(model.hasSuccessfulHealthQuery)

        provider.shouldFailQuery = true
        await model.requestAccessAndLoadRecentData()

        XCTAssertTrue(model.recentRecords.isEmpty)
        XCTAssertFalse(model.hasSuccessfulHealthQuery)
        XCTAssertNotNil(model.healthDataError)
    }

    @MainActor
    func testAuthorizationFailureDoesNotMarkRequestCompleteOrQuery() async {
        let provider = StubHealthDataProvider(records: [], shouldFailAuthorization: true)
        let model = VitalRouteModel(healthData: provider)

        await model.requestAccessAndLoadRecentData()

        XCTAssertFalse(model.authorizationRequestCompleted)
        XCTAssertFalse(model.hasSuccessfulHealthQuery)
        XCTAssertEqual(provider.queryCount, 0)
        XCTAssertNotNil(model.healthDataError)
    }
}

@MainActor
private final class StubHealthDataProvider: HealthDataProviding {
    let records: [HealthRecord]
    var shouldFailQuery: Bool
    let shouldFailAuthorization: Bool
    private(set) var queryCount = 0

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

    func requestReadAuthorization() async throws {
        if shouldFailAuthorization {
            throw StubHealthDataError.authorizationFailed
        }
    }

    func queryRecentRecords(since startDate: Date, perMetricLimit: Int) async throws -> [HealthRecord] {
        queryCount += 1
        if shouldFailQuery {
            throw StubHealthDataError.queryFailed
        }
        return records
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
