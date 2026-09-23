import XCTest
@testable import VitalRoute

final class HealthKitServiceTests: XCTestCase {
    func testAuthorizationErrorMappingPassesUnderlyingErrorThrough() {
        let underlying = NSError(domain: "com.apple.healthkit", code: 42)

        let mapped = HealthKitServiceError.authorizationError(granted: false, error: underlying)

        XCTAssertEqual(mapped as NSError?, underlying as NSError?)
    }

    func testAuthorizationErrorMappingThrowsWhenNotGrantedWithoutError() {
        let mapped = HealthKitServiceError.authorizationError(granted: false, error: nil)

        XCTAssertEqual(mapped as? HealthKitServiceError, .authorizationFailed)
        XCTAssertNotNil((mapped as? LocalizedError)?.errorDescription)
    }

    func testAuthorizationErrorMappingReturnsNilWhenGranted() {
        XCTAssertNil(HealthKitServiceError.authorizationError(granted: true, error: nil))
    }
}
