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
    func testTransientReadFailureDoesNotSettleAsNoCredential() async throws {
        let secureStore = FlakySecureValueStore()
        try secureStore.saveValue("token-for-a", forKey: DestinationCredentialStore.storageKey(for: endpointA))
        secureStore.failReads = true
        let store = DestinationCredentialStore(secureStore: secureStore)

        await store.loadCredential(for: endpointA)

        // A locked device makes Keychain reads fail transiently. Settling
        // here would present "no credential" — and cache it — for a key the
        // user already saved, so the store stays unsettled and retryable.
        XCTAssertFalse(store.isLoaded)
        XCTAssertFalse(store.hasCredential)
        XCTAssertNil(store.loadedToken)
        XCTAssertEqual(store.credentialEndpoint, "")
        XCTAssertEqual(
            store.storageError,
            "The saved API key could not be read from secure storage. VitalRoute will retry when secure storage is available."
        )
    }

    @MainActor
    func testRetryAfterTransientReadFailureRecoversCredential() async throws {
        let secureStore = FlakySecureValueStore()
        try secureStore.saveValue("token-for-a", forKey: DestinationCredentialStore.storageKey(for: endpointA))
        secureStore.failReads = true
        let store = DestinationCredentialStore(secureStore: secureStore)
        await store.loadCredential(for: endpointA)
        XCTAssertFalse(store.isLoaded)

        // Secure storage became readable: the retried load recovers the
        // credential without user action.
        secureStore.failReads = false
        await store.loadCredential(for: endpointA)

        XCTAssertTrue(store.isLoaded)
        XCTAssertTrue(store.hasCredential)
        XCTAssertEqual(store.loadedToken, "token-for-a")
        XCTAssertEqual(store.credentialEndpoint, endpointA)
        XCTAssertNil(store.storageError)
    }

    @MainActor
    func testFailedReadForNewEndpointKeepsPreviousEndpointsState() async throws {
        let secureStore = FlakySecureValueStore()
        try secureStore.saveValue("token-for-a", forKey: DestinationCredentialStore.storageKey(for: endpointA))
        let store = DestinationCredentialStore(secureStore: secureStore)
        await store.loadCredential(for: endpointA)
        XCTAssertTrue(store.hasCredential)

        secureStore.failReads = true
        await store.loadCredential(for: endpointB)

        // The failed read for B must not tear down A's settled state: until
        // a retry succeeds, the loaded credential still describes A, and
        // endpoint/token pairing stays intact.
        XCTAssertTrue(store.hasCredential)
        XCTAssertEqual(store.loadedToken, "token-for-a")
        XCTAssertEqual(store.credentialEndpoint, endpointA)
        XCTAssertEqual(
            store.storageError,
            "The saved API key could not be read from secure storage. VitalRoute will retry when secure storage is available."
        )

        // Storage recovers and B's key is present: the same retried load
        // now settles B's state.
        secureStore.failReads = false
        try secureStore.saveValue("token-for-b", forKey: DestinationCredentialStore.storageKey(for: endpointB))
        await store.loadCredential(for: endpointB)

        XCTAssertTrue(store.isLoaded)
        XCTAssertEqual(store.loadedToken, "token-for-b")
        XCTAssertEqual(store.credentialEndpoint, endpointB)
        XCTAssertNil(store.storageError)
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

    func migrateToBackgroundAccessibility() throws {}
}

private struct ThrowingSecureValueStoreError: Error {}

/// Fails every read until `failReads` is cleared, standing in for the
/// locked-device Keychain state (`errSecInteractionNotAllowed`).
private final class FlakySecureValueStore: SecureValueStoring, @unchecked Sendable {
    var values: [String: String] = [:]
    var failReads = false

    func readValue(forKey key: String) throws -> String? {
        if failReads {
            throw ThrowingSecureValueStoreError()
        }
        return values[key]
    }

    func saveValue(_ value: String, forKey key: String) throws {
        values[key] = value
    }

    func removeValue(forKey key: String) throws {
        values.removeValue(forKey: key)
    }

    func migrateToBackgroundAccessibility() throws {}
}
