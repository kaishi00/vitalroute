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
    func testTransientReadFailureDoesNotSettleAsUnconfigured() async throws {
        let secureStore = FlakySecureValueStore()
        secureStore.values["destination.endpoint"] = "https://health.example.org/v1/ingest"
        secureStore.failReads = true
        let configurationStore = DestinationConfigurationStore(secureStore: secureStore)

        await configurationStore.loadSavedEndpoint()

        // A locked device makes Keychain reads fail transiently. That must
        // never settle the store as "no destination": settling here is what
        // erased the saved endpoint from the UI on build 6 and made the
        // engine report it missing. The store stays unsettled so a retry can
        // recover without user action.
        XCTAssertFalse(configurationStore.isLoaded)
        XCTAssertFalse(configurationStore.isConfigured)
        XCTAssertEqual(configurationStore.savedEndpoint, "")
        XCTAssertEqual(
            configurationStore.storageError,
            "The saved destination could not be read from secure storage. VitalRoute will retry when secure storage is available."
        )
    }

    @MainActor
    func testRetryAfterTransientReadFailureRecoversEndpoint() async throws {
        let secureStore = FlakySecureValueStore()
        secureStore.values["destination.endpoint"] = "https://health.example.org/v1/ingest"
        secureStore.failReads = true
        let configurationStore = DestinationConfigurationStore(secureStore: secureStore)
        await configurationStore.loadSavedEndpoint()
        XCTAssertFalse(configurationStore.isLoaded)

        // Protected data became available (the device was unlocked): the
        // retried load succeeds and the endpoint reappears on its own.
        secureStore.failReads = false
        await configurationStore.loadSavedEndpoint()

        XCTAssertTrue(configurationStore.isLoaded)
        XCTAssertTrue(configurationStore.isConfigured)
        XCTAssertEqual(configurationStore.savedEndpoint, "https://health.example.org/v1/ingest")
        XCTAssertNil(configurationStore.storageError)
    }

    @MainActor
    func testSettledStoreIsNotDisturbedByLaterFailureAttempts() async throws {
        let secureStore = FlakySecureValueStore()
        secureStore.values["destination.endpoint"] = "https://health.example.org/v1/ingest"
        let configurationStore = DestinationConfigurationStore(secureStore: secureStore)
        await configurationStore.loadSavedEndpoint()
        XCTAssertTrue(configurationStore.isLoaded)

        secureStore.failReads = true
        await configurationStore.loadSavedEndpoint()

        XCTAssertTrue(configurationStore.isLoaded)
        XCTAssertTrue(configurationStore.isConfigured)
        XCTAssertEqual(configurationStore.savedEndpoint, "https://health.example.org/v1/ingest")
        XCTAssertNil(configurationStore.storageError)
    }

    @MainActor
    func testSaveDuringInFlightFailingReadKeepsSavedState() async throws {
        let secureStore = FailingGatedReadStore()
        let configurationStore = DestinationConfigurationStore(secureStore: secureStore)
        async let loadResult = configurationStore.loadSavedEndpoint()
        // Registered after the child: scope-exit unwinding runs in reverse
        // registration order, so a throwing exit releases the gate before
        // the implicit await of the async-let child.
        defer { secureStore.releaseRead() }

        let readEntered = await waitForReadEntry(secureStore, timeout: .seconds(5))
        XCTAssertTrue(readEntered, "gated read never started")

        try configurationStore.save(endpoint: "https://new.example.org/v1/ingest")

        secureStore.releaseRead()
        await loadResult

        // The save settled authoritative state; the failing read that landed
        // afterwards must neither clobber it nor surface a stale error.
        XCTAssertEqual(configurationStore.savedEndpoint, "https://new.example.org/v1/ingest")
        XCTAssertTrue(configurationStore.isLoaded)
        XCTAssertTrue(configurationStore.isConfigured)
        XCTAssertNil(configurationStore.storageError)
        // The gate was released by the defer, not the fail-safe deadline.
        XCTAssertFalse(secureStore.hitFailSafe, "gated read hit its fail-safe deadline")
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

    @MainActor
    func testSaveDuringInFlightLoadKeepsSavedState() async throws {
        let secureStore = GatedReadStore()
        let configurationStore = DestinationConfigurationStore(secureStore: secureStore)
        async let loadResult = configurationStore.loadSavedEndpoint()
        // Registered after the child: scope-exit unwinding runs in reverse
        // registration order, so a throwing exit releases the gate before
        // the implicit await of the async-let child.
        defer { secureStore.releaseRead() }

        let readEntered = await waitForReadEntry(secureStore, timeout: .seconds(5))
        XCTAssertTrue(readEntered, "gated read never started")

        try configurationStore.save(endpoint: "https://new.example.org/v1/ingest")

        secureStore.releaseRead()
        await loadResult

        XCTAssertEqual(configurationStore.savedEndpoint, "https://new.example.org/v1/ingest")
        XCTAssertEqual(secureStore.savedValue, "https://new.example.org/v1/ingest")
        XCTAssertTrue(configurationStore.isConfigured)
        XCTAssertNil(configurationStore.storageError)
        // The settled-state guard discards the read outcome here, so a missed
        // release would otherwise hide behind a slow pass.
        XCTAssertFalse(secureStore.hitFailSafe, "gated read hit its fail-safe deadline")
    }

    @MainActor
    func testGatedReadPollExitsAtDeadlineWhenLoadNeverStarts() async throws {
        let secureStore = GatedReadStore()
        let configurationStore = DestinationConfigurationStore(secureStore: secureStore)
        // A settled store makes loadSavedEndpoint() return without reading,
        // so the poll must exit at its deadline instead of hanging.
        try configurationStore.save(endpoint: "https://settled.example.org/v1/ingest")

        async let loadResult = configurationStore.loadSavedEndpoint()
        let readEntered = await waitForReadEntry(secureStore, timeout: .milliseconds(200))

        XCTAssertFalse(readEntered, "load should not perform a read once state is settled")
        await loadResult

        XCTAssertEqual(configurationStore.savedEndpoint, "https://settled.example.org/v1/ingest")
        XCTAssertTrue(configurationStore.isLoaded)
    }

    @MainActor
    func testFailedSaveDuringInFlightLoadStillCompletesTheLoad() async throws {
        let secureStore = GatedReadStore()
        let configurationStore = DestinationConfigurationStore(secureStore: secureStore)
        async let loadResult = configurationStore.loadSavedEndpoint()
        // Registered after the child so a throwing exit releases the gate
        // before the implicit await of the async-let child.
        defer { secureStore.releaseRead() }

        let readEntered = await waitForReadEntry(secureStore, timeout: .seconds(5))
        XCTAssertTrue(readEntered)

        // A rejected endpoint throws before any state settles, so the
        // in-flight read must still commit its result afterwards.
        XCTAssertThrowsError(try configurationStore.save(endpoint: "not a valid url"))

        secureStore.releaseRead()
        await loadResult

        XCTAssertEqual(configurationStore.savedEndpoint, "https://old.example.org/v1/ingest")
        XCTAssertTrue(configurationStore.isLoaded)
        XCTAssertNil(configurationStore.storageError)
    }

    @MainActor
    func testThrownErrorDuringGatedLoadReleasesReadBeforeChildAwait() async throws {
        let secureStore = GatedReadStore()
        let configurationStore = DestinationConfigurationStore(secureStore: secureStore)

        do {
            try await performFailingSaveWhileGated(configurationStore, secureStore: secureStore)
            XCTFail("expected the invalid endpoint save to throw")
        } catch let error as DestinationConfigurationError {
            XCTAssertEqual(error, .httpsRequired)
        }

        // If the deferred release ran only after the implicit child await at
        // scope exit, the read would have spun to its fail-safe before the
        // gate opened; the flags distinguish the two orderings without
        // timing the test.
        XCTAssertTrue(secureStore.isReadEntered)
        XCTAssertFalse(secureStore.hitFailSafe, "gate was released only by the fail-safe, not the defer")
        // The error escaping must not strand the child: with the gate
        // released during unwinding, the load commits its read.
        XCTAssertEqual(configurationStore.savedEndpoint, "https://old.example.org/v1/ingest")
        XCTAssertTrue(configurationStore.isLoaded)
        XCTAssertNil(configurationStore.storageError)
    }

    @MainActor
    private func waitForReadEntry(_ secureStore: GatedReadStore, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock().now + timeout
        while !secureStore.isReadEntered {
            if ContinuousClock().now >= deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    @MainActor
    private func waitForReadEntry(_ secureStore: FailingGatedReadStore, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock().now + timeout
        while !secureStore.isReadEntered {
            if ContinuousClock().now >= deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    /// Owns the gated async-let child and throws out of the scope while the
    /// read is still gated, so the caller can observe whether the deferred
    /// release ran before the child was awaited.
    @MainActor
    private func performFailingSaveWhileGated(
        _ configurationStore: DestinationConfigurationStore,
        secureStore: GatedReadStore
    ) async throws {
        async let loadResult = configurationStore.loadSavedEndpoint()
        // Registered after the child: scope-exit unwinding runs in reverse
        // registration order, so the throwing exit releases the gate before
        // the implicit await of the async-let child.
        defer { secureStore.releaseRead() }

        let readEntered = await waitForReadEntry(secureStore, timeout: .seconds(5))
        XCTAssertTrue(readEntered, "gated read never started")

        try configurationStore.save(endpoint: "not a valid url")

        // Unreachable on the exercised path: the save above always throws,
        // and the deferred release during scope-exit unwinding is the
        // mechanism under test. This tail only documents the non-throwing
        // shape.
        secureStore.releaseRead()
        await loadResult
    }
}

private struct ThrowingSecureValueStoreError: Error {}

/// Fails every read until `failReads` is cleared, standing in for the
/// locked-device Keychain state (`errSecInteractionNotAllowed`). Writes and
/// removals keep working, as they do against real Keychain items that are
/// already background-accessible.
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

/// Blocks the read until released and then fails it, so a save() can be
/// interleaved with a read that is destined to fail.
private final class FailingGatedReadStore: SecureValueStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var readEntered = false
    private var released = false
    private var failSafeTripped = false

    var isReadEntered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return readEntered
    }

    var hitFailSafe: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failSafeTripped
    }

    func releaseRead() {
        lock.lock()
        released = true
        lock.unlock()
    }

    func readValue(forKey key: String) throws -> String? {
        let failSafeDeadline = Date().addingTimeInterval(10)
        lock.lock()
        readEntered = true
        while !released && Date() < failSafeDeadline {
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.005)
            lock.lock()
        }
        let wasReleased = released
        if !wasReleased {
            failSafeTripped = true
        }
        lock.unlock()
        throw ThrowingSecureValueStoreError()
    }

    func saveValue(_ value: String, forKey key: String) throws {}

    func removeValue(forKey key: String) throws {}

    func migrateToBackgroundAccessibility() throws {}
}

/// Blocks the detached Keychain read until the test releases it, so a
/// save() can be interleaved while the load is in flight. The internal wait
/// is deadline-bounded as a fail-safe: even a regression in the test flow
/// cannot spin this thread (and the suite) forever.
private final class GatedReadStore: SecureValueStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var readEntered = false
    private var released = false
    private var failSafeTripped = false
    private(set) var savedValue: String?

    var isReadEntered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return readEntered
    }

    var hitFailSafe: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failSafeTripped
    }

    func releaseRead() {
        lock.lock()
        released = true
        lock.unlock()
    }

    func readValue(forKey key: String) throws -> String? {
        let failSafeDeadline = Date().addingTimeInterval(10)
        lock.lock()
        readEntered = true
        while !released && Date() < failSafeDeadline {
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.005)
            lock.lock()
        }
        let wasReleased = released
        if !wasReleased {
            failSafeTripped = true
        }
        lock.unlock()
        // The fail-safe must fail the test, not paper over a missed release
        // by returning data the waiting assertions would accept.
        guard wasReleased else {
            throw ThrowingSecureValueStoreError()
        }
        return "https://old.example.org/v1/ingest"
    }

    func saveValue(_ value: String, forKey key: String) throws {
        lock.lock()
        savedValue = value
        lock.unlock()
    }

    func removeValue(forKey key: String) throws {}

    func migrateToBackgroundAccessibility() throws {}
}

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

    func migrateToBackgroundAccessibility() throws {}
}
