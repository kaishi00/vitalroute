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

    @MainActor
    func testConfigurationStoreUsesSecureStorage() async throws {
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

    @MainActor
    func testStoreStartsUnloadedAndLoadsSavedEndpointAsynchronously() async throws {
        let secureStore = InMemorySecureValueStore()
        secureStore.values["destination.endpoint"] = "https://health.example.org/v1/ingest"
        let configurationStore = DestinationConfigurationStore(secureStore: secureStore)

        XCTAssertFalse(configurationStore.isLoaded)
        XCTAssertFalse(configurationStore.isConfigured)
        XCTAssertNil(configurationStore.storageError)

        await configurationStore.loadSavedEndpoint()

        XCTAssertTrue(configurationStore.isLoaded)
        XCTAssertEqual(configurationStore.savedEndpoint, "https://health.example.org/v1/ingest")
        XCTAssertTrue(configurationStore.isConfigured)
        XCTAssertNil(configurationStore.storageError)
    }

    @MainActor
    func testLoadWithoutSavedEndpointStaysUnconfigured() async throws {
        let configurationStore = DestinationConfigurationStore(secureStore: InMemorySecureValueStore())

        await configurationStore.loadSavedEndpoint()

        XCTAssertTrue(configurationStore.isLoaded)
        XCTAssertEqual(configurationStore.savedEndpoint, "")
        XCTAssertFalse(configurationStore.isConfigured)
        XCTAssertNil(configurationStore.storageError)
    }

    @MainActor
    func testLoadSurfacesStorageReadErrors() async throws {
        let configurationStore = DestinationConfigurationStore(secureStore: ThrowingSecureValueStore())

        await configurationStore.loadSavedEndpoint()

        XCTAssertTrue(configurationStore.isLoaded)
        XCTAssertFalse(configurationStore.isConfigured)
        XCTAssertEqual(
            configurationStore.storageError,
            "The saved destination could not be read from secure storage."
        )
    }

    @MainActor
    func testSecondLoadDoesNotOverwriteSettledState() async throws {
        let secureStore = InMemorySecureValueStore()
        secureStore.values["destination.endpoint"] = "https://first.example.org/v1/ingest"
        let configurationStore = DestinationConfigurationStore(secureStore: secureStore)

        await configurationStore.loadSavedEndpoint()

        secureStore.values["destination.endpoint"] = "https://second.example.org/v1/ingest"
        await configurationStore.loadSavedEndpoint()

        XCTAssertEqual(configurationStore.savedEndpoint, "https://first.example.org/v1/ingest")
    }

    @MainActor
    func testSavePreventsSubsequentLoadFromClobberingState() async throws {
        let configurationStore = DestinationConfigurationStore(secureStore: InMemorySecureValueStore())

        try configurationStore.save(endpoint: "https://saved.example.org/v1/ingest")
        await configurationStore.loadSavedEndpoint()

        XCTAssertEqual(configurationStore.savedEndpoint, "https://saved.example.org/v1/ingest")
        XCTAssertTrue(configurationStore.isConfigured)
    }
}

private struct ThrowingSecureValueStoreError: Error {}

// Test doubles are only ever touched from the store's detached read task and
// the test body, which are serialized by await points.
private final class InMemorySecureValueStore: SecureValueStoring, @unchecked Sendable {
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

private final class ThrowingSecureValueStore: SecureValueStoring, @unchecked Sendable {
    func readValue(forKey key: String) throws -> String? {
        throw ThrowingSecureValueStoreError()
    }

    func saveValue(_ value: String, forKey key: String) throws {}

    func removeValue(forKey key: String) throws {}
}
