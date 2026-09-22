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
}

@MainActor
private final class StubHealthDataProvider: HealthDataProviding {
    let records: [HealthRecord]
    let shouldFailQuery: Bool

    init(records: [HealthRecord], shouldFailQuery: Bool = false) {
        self.records = records
        self.shouldFailQuery = shouldFailQuery
    }

    var isAvailable: Bool { true }

    func requestReadAuthorization() async throws {}

    func queryRecentRecords(since startDate: Date, perMetricLimit: Int) async throws -> [HealthRecord] {
        if shouldFailQuery {
            throw StubHealthDataError.queryFailed
        }
        return records
    }
}

private enum StubHealthDataError: LocalizedError {
    case queryFailed

    var errorDescription: String? {
        "The test query failed."
    }
}
