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

    func testRejectsQueryStringsFragmentsAndInvalidPorts() {
        XCTAssertThrowsError(try DestinationConfiguration(endpoint: "https://health.example.org/ingest?token=secret"))
        XCTAssertThrowsError(try DestinationConfiguration(endpoint: "https://health.example.org/ingest#section"))
        XCTAssertThrowsError(try DestinationConfiguration(endpoint: "https://health.example.org:70000/ingest"))
    }

    func testConfigurationStoreUsesSecureStorage() async throws {
        try await MainActor.run {
            let secureStore = InMemorySecureValueStore()
            let configurationStore = DestinationConfigurationStore(secureStore: secureStore)
            let endpoint = "https://health.example.org/v1/ingest"

            try configurationStore.save(endpoint: endpoint)
            XCTAssertEqual(secureStore.values["destination.endpoint"], endpoint)
            XCTAssertEqual(configurationStore.savedEndpoint, endpoint)

            try configurationStore.clear()
            XCTAssertNil(secureStore.values["destination.endpoint"])
            XCTAssertFalse(configurationStore.isConfigured)
        }
    }
}

@MainActor
private final class InMemorySecureValueStore: SecureValueStoring {
    var values: [String: String] = [:]

    func readValue(forKey key: String) throws -> String? {
        values[key]
    }

    func saveValue(_ value: String, forKey key: String) throws {
        values[key] = value
    }

    func removeValue(forKey key: String) throws {
        values.removeValue(forKey: key)
    }
}
