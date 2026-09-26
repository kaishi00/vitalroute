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

    /// The export-compliance declaration only works as a boolean: a string
    /// "false" (e.g. from a quoted project.yml value) is silently ignored
    /// by upload validation and the per-build "Missing Compliance" step
    /// returns. Flip the value only if non-exempt encryption is ever added.
    func testExportComplianceDeclarationIsBooleanFalse() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let value = try XCTUnwrap(
            info["ITSAppUsesNonExemptEncryption"],
            "ITSAppUsesNonExemptEncryption missing from Info.plist"
        )
        XCTAssertEqual(
            value as? Bool, false,
            "ITSAppUsesNonExemptEncryption must be boolean false, got \(type(of: value))"
        )
    }
}
