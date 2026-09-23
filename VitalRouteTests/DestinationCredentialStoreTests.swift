import XCTest
@testable import VitalRoute

final class DestinationCredentialStoreTests: XCTestCase {
    private let endpointA = "https://health-a.example.org/v1/records"
    private let endpointB = "https://health-b.example.org/v1/records"

    @MainActor
    func testSaveLoadRemoveRoundTrip() async throws {
        let secureStore = InMemorySecureValueStore()
        let store = DestinationCredentialStore(secureStore: secureStore)

        try store.saveCredential("token-for-a", for: endpointA)
        XCTAssertTrue(store.hasCredential)
        XCTAssertEqual(store.loadedToken, "token-for-a")
        XCTAssertEqual(secureStore.values[DestinationCredentialStore.storageKey(for: endpointA)], "token-for-a")

        try store.removeCredential(for: endpointA)
        XCTAssertFalse(store.hasCredential)
        XCTAssertNil(store.loadedToken)
        XCTAssertNil(secureStore.values[DestinationCredentialStore.storageKey(for: endpointA)])
    }

    @MainActor
    func testSaveTrimsAndRejectsEmptyTokens() throws {
        let secureStore = InMemorySecureValueStore()
        let store = DestinationCredentialStore(secureStore: secureStore)

        try store.saveCredential("  padded-token  ", for: endpointA)
        XCTAssertEqual(store.loadedToken, "padded-token")

        XCTAssertThrowsError(try store.saveCredential("   ", for: endpointA)) { error in
            XCTAssertEqual(error as? DestinationCredentialStoreError, .emptyToken)
        }
        XCTAssertThrowsError(try store.saveCredential("", for: endpointA))
    }

    @MainActor
    func testReplaceCredentialOverwritesForSameEndpoint() throws {
        let secureStore = InMemorySecureValueStore()
        let store = DestinationCredentialStore(secureStore: secureStore)

        try store.saveCredential("first-token", for: endpointA)
        try store.saveCredential("second-token", for: endpointA)

        XCTAssertEqual(store.loadedToken, "second-token")
        XCTAssertEqual(secureStore.values[DestinationCredentialStore.storageKey(for: endpointA)], "second-token")
        XCTAssertEqual(secureStore.values.count, 1)
    }

    @MainActor
    func testEndpointsAreIsolatedByKey() throws {
        let secureStore = InMemorySecureValueStore()
        let store = DestinationCredentialStore(secureStore: secureStore)

        try store.saveCredential("token-for-a", for: endpointA)
        try store.saveCredential("token-for-b", for: endpointB)

        XCTAssertEqual(
            DestinationCredentialStore.storageKey(for: endpointA),
            DestinationCredentialStore.storageKey(for: endpointA)
        )
        XCTAssertNotEqual(
            DestinationCredentialStore.storageKey(for: endpointA),
            DestinationCredentialStore.storageKey(for: endpointB)
        )
        XCTAssertEqual(secureStore.values.count, 2)
        // The active state describes the most recently saved endpoint; the
        // other endpoint's key still exists but is not exposed as current.
        XCTAssertEqual(store.credentialEndpoint, endpointB)
        XCTAssertEqual(store.loadedToken, "token-for-b")
    }

    @MainActor
    func testLoadCredentialForEndpointWithoutOneReportsNoCredential() async throws {
        let secureStore = InMemorySecureValueStore()
        try secureStore.saveValue("token-for-a", forKey: DestinationCredentialStore.storageKey(for: endpointA))
        let store = DestinationCredentialStore(secureStore: secureStore)

        await store.loadCredential(for: endpointB)

        XCTAssertTrue(store.isLoaded)
        XCTAssertFalse(store.hasCredential)
        XCTAssertEqual(store.credentialEndpoint, endpointB)
        XCTAssertNil(store.loadedToken)
        XCTAssertNil(store.storageError)
    }

    @MainActor
    func testLoadCredentialPicksUpSavedCredential() async throws {
        let secureStore = InMemorySecureValueStore()
        try secureStore.saveValue("token-for-a", forKey: DestinationCredentialStore.storageKey(for: endpointA))
        let store = DestinationCredentialStore(secureStore: secureStore)

        await store.loadCredential(for: endpointA)

        XCTAssertTrue(store.isLoaded)
        XCTAssertTrue(store.hasCredential)
        XCTAssertEqual(store.loadedToken, "token-for-a")
    }

    @MainActor
    func testLoadSurfacesStorageReadErrors() async throws {
        let store = DestinationCredentialStore(secureStore: ThrowingSecureValueStore())

        await store.loadCredential(for: endpointA)

        XCTAssertTrue(store.isLoaded)
        XCTAssertFalse(store.hasCredential)
        XCTAssertEqual(
            store.storageError,
            "The saved API key could not be read from secure storage."
        )
    }

    @MainActor
    func testLoadIsNoOpOnceSettledForSameEndpoint() async throws {
        let secureStore = InMemorySecureValueStore()
        let store = DestinationCredentialStore(secureStore: secureStore)
        try store.saveCredential("current", for: endpointA)

        await store.loadCredential(for: endpointA)

        XCTAssertEqual(store.loadedToken, "current")
        XCTAssertTrue(store.hasCredential)
    }

    @MainActor
    func testRemovingPreviousEndpointsCredentialDoesNotAffectCurrent() throws {
        let secureStore = InMemorySecureValueStore()
        let store = DestinationCredentialStore(secureStore: secureStore)
        try store.saveCredential("token-for-b", for: endpointB)

        // The endpoint-change flow: remove the old destination's credential,
        // then the new destination has none until the user saves one.
        try store.removeCredential(for: endpointA)

        XCTAssertEqual(secureStore.values[DestinationCredentialStore.storageKey(for: endpointB)], "token-for-b")
        XCTAssertEqual(store.loadedToken, "token-for-b")
        XCTAssertTrue(store.hasCredential)
        XCTAssertNil(secureStore.values[DestinationCredentialStore.storageKey(for: endpointA)])
    }
}

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

private struct ThrowingSecureValueStoreError: Error {}

private final class ThrowingSecureValueStore: SecureValueStoring, @unchecked Sendable {
    func readValue(forKey key: String) throws -> String? {
        throw ThrowingSecureValueStoreError()
    }

    func saveValue(_ value: String, forKey key: String) throws {
        throw ThrowingSecureValueStoreError()
    }

    func removeValue(forKey key: String) throws {
        throw ThrowingSecureValueStoreError()
    }
}
