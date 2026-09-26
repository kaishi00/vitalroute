import XCTest

final class AppConfigurationTests: XCTestCase {

    /// Upload validation (ITMS-90683) rejects a HealthKit-entitled binary
    /// missing either purpose string, and that failure only surfaces at
    /// TestFlight upload time — guard it here instead. The test host is the
    /// app, so Bundle.main carries the generated Info.plist.
    func testHealthKitPurposeStringsArePresent() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        for key in ["NSHealthShareUsageDescription", "NSHealthUpdateUsageDescription"] {
            let value = try XCTUnwrap(info[key] as? String, "\(key) missing from Info.plist")
            XCTAssertFalse(
                value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(key) is blank"
            )
        }
    }
}
