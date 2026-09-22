import XCTest
@testable import VitalRoute

final class DestinationConfigurationTests: XCTestCase {
    func testAcceptsHTTPSDestinationAndTrimsWhitespace() throws {
        let configuration = try DestinationConfiguration(endpoint: "  https://health.example.org/v1/ingest  ")

        XCTAssertEqual(configuration.endpoint.absoluteString, "https://health.example.org/v1/ingest")
    }

    func testRejectsInsecureHTTPDestination() {
        XCTAssertThrowsError(try DestinationConfiguration(endpoint: "http://health.example.org/ingest")) { error in
            XCTAssertEqual(error as? DestinationConfigurationError, .httpsRequired)
        }
    }

    func testRejectsMissingHostAndEmbeddedCredentials() {
        XCTAssertThrowsError(try DestinationConfiguration(endpoint: "https:///ingest"))
        XCTAssertThrowsError(try DestinationConfiguration(endpoint: "https://user:secret@health.example.org/ingest"))
    }
}
