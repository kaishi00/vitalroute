import UIKit
import XCTest
@testable import VitalRoute

/// End-to-end recovery tests: a locked-device launch leaves the engine
/// waiting on unreadable secure storage; the coordinator's retry must bring
/// the stores back, report the configuration to the engine, and never touch
/// queue ownership. Uses a private notification center so no test depends on
/// system timing.
@MainActor
final class DestinationRecoveryTests: XCTestCase {
    private var tempDirectory: URL!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var center: NotificationCenter!
    /// Shared controllable clock; the fixture engines read it for backoff
    /// and retry arithmetic.
    private var clock: ClockBox!

    private let endpoint = "https://health.example.org/v1/records"
    private let token = "recovery-test-token-0001"

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vitalroute-recovery-tests-\(UUID().uuidString)")
        defaultsSuiteName = "recovery-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        center = NotificationCenter()
        clock = ClockBox()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: Fixtures

    private func record(_ id: Int) -> HealthRecord {
        HealthRecord(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            metric: .steps,
            startDate: Date(timeIntervalSince1970: 1_735_689_600),
            endDate: Date(timeIntervalSince1970: 1_735_689_660),
            data: .quantity(QuantityData(value: Double(id), unit: "count"))
        )
    }

    private func makeEngine(provider: ScriptedHealthProvider, client: ScriptedSyncClient) -> AutomaticSyncEngine {
        let box = self.clock!
        return AutomaticSyncEngine(
            healthData: provider,
            client: client,
            stateStore: SyncStateStore(directory: tempDirectory),
            outbox: Outbox(directory: tempDirectory),
            defaults: defaults,
            now: { box.now }
        )
    }

    private func makeCoordinator(
        destinationStore: DestinationConfigurationStore,
        credentialStore: DestinationCredentialStore,
        secureStore: RecordingSecureStore,
        engine: AutomaticSyncEngine,
        selectionStore: ExportSelectionStore? = nil
    ) -> DestinationRecoveryCoordinator {
        // Recovery mirrors a real user setup: at least one category was
        // selected when automatic sync was enabled. An empty selection would
        // take the engine to its own honest pause instead.
        let selection: ExportSelectionStore
        if let selectionStore {
            selection = selectionStore
        } else {
            selection = ExportSelectionStore(defaults: defaults)
            selection.setMetric(.steps, selected: true)
        }
        return DestinationRecoveryCoordinator(
            destinationStore: destinationStore,
            credentialStore: credentialStore,
            selectionStore: selection,
            engine: engine,
            secureStore: secureStore,
            notificationCenter: center
        )
    }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "timed out waiting for \(description)", file: file, line: line)
    }

    // MARK: Recovery attempts

    func testRecoverWithStillUnavailableStorageLeavesEngineWaiting() async throws {
        let secureStore = RecordingSecureStore()
        secureStore.values["destination.endpoint"] = endpoint
        secureStore.values[DestinationCredentialStore.storageKey(for: endpoint)] = token
        secureStore.failAllReads = true

        defaults.set(true, forKey: "automaticSync.enabled")
        let relaunchedProvider = ScriptedHealthProvider()
        let relaunched = makeEngine(provider: relaunchedProvider, client: ScriptedSyncClient())
        await relaunched.restorePausedOnSecureStorage()

        let coordinator = makeCoordinator(
            destinationStore: DestinationConfigurationStore(secureStore: secureStore),
            credentialStore: DestinationCredentialStore(secureStore: secureStore),
            secureStore: secureStore,
            engine: relaunched
        )
        await coordinator.recoverNow()

        XCTAssertTrue(relaunched.isEnabled, "a failed read must never turn automatic sync off")
        XCTAssertEqual(relaunched.mode, .paused(.secureStorageUnavailable), "a failed attempt must not report configuration")
        XCTAssertTrue(relaunchedProvider.observedMetrics.isEmpty)
        XCTAssertGreaterThanOrEqual(secureStore.migrateCallCount, 1, "every attempt retries the accessibility migration")
    }

    func testRecoverAfterStorageReturnsReportsConfigurationAndDeliversQueuedWork() async throws {
        let secureStore = RecordingSecureStore()
        secureStore.values["destination.endpoint"] = endpoint
        secureStore.values[DestinationCredentialStore.storageKey(for: endpoint)] = token

        // The prior process left one change queued undelivered.
        let originalProvider = ScriptedHealthProvider()
        originalProvider.script = [.steps: [HealthChangePage(
            additions: [record(1)],
            deletions: [],
            anchorData: Data("a1".utf8),
            isFull: false
        )]]
        let originalClient = ScriptedSyncClient()
        originalClient.failNextDelivery(with: .connectionFailed)
        let original = makeEngine(provider: originalProvider, client: originalClient)
        defaults.set(true, forKey: "automaticSync.enabled")
        _ = await original.enable(destination: endpoint, token: token, metrics: [.steps])
        await original.waitUntilIdle()
        XCTAssertEqual(original.pendingCount, 1)

        // Locked-device relaunch: waiting on unreadable storage.
        let relaunchedProvider = ScriptedHealthProvider()
        let relaunchedClient = ScriptedSyncClient()
        let relaunched = makeEngine(provider: relaunchedProvider, client: relaunchedClient)
        await relaunched.restorePausedOnSecureStorage()

        // The device was unlocked; secure storage is readable again. The
        // unlock also means the first process's delivery backoff has long
        // elapsed.
        clock.advance(by: 61)
        let coordinator = makeCoordinator(
            destinationStore: DestinationConfigurationStore(secureStore: secureStore),
            credentialStore: DestinationCredentialStore(secureStore: secureStore),
            secureStore: secureStore,
            engine: relaunched
        )
        await coordinator.recoverNow()
        await relaunched.waitUntilIdle()

        XCTAssertEqual(relaunched.mode, .active)
        XCTAssertFalse(relaunchedProvider.observedMetrics.isEmpty, "recovery re-arms observers")
        let delivered = relaunchedClient.sentChangeBatches.flatMap(\.changes)
        XCTAssertEqual(
            delivered,
            [.upsert(record(1))],
            "the queue survived the wait and reached its original destination"
        )
        XCTAssertEqual(relaunchedClient.sentChangeBatches.first?.endpoint.absoluteString, endpoint)
        XCTAssertEqual(relaunched.pendingCount, 0)
        XCTAssertGreaterThanOrEqual(secureStore.migrateCallCount, 1)
    }

    func testRecoverDoesNotPairEndpointWithUnsettledCredential() async throws {
        let secureStore = RecordingSecureStore()
        secureStore.values["destination.endpoint"] = endpoint
        secureStore.values[DestinationCredentialStore.storageKey(for: endpoint)] = token
        secureStore.failingKeys = [DestinationCredentialStore.storageKey(for: endpoint)]

        // The persisted flag is read at engine init: a relaunch finds
        // automatic sync on before anything else happens.
        defaults.set(true, forKey: "automaticSync.enabled")
        let relaunchedProvider = ScriptedHealthProvider()
        let relaunchedClient = ScriptedSyncClient()
        let relaunched = makeEngine(provider: relaunchedProvider, client: relaunchedClient)
        await relaunched.restorePausedOnSecureStorage()

        let coordinator = makeCoordinator(
            destinationStore: DestinationConfigurationStore(secureStore: secureStore),
            credentialStore: DestinationCredentialStore(secureStore: secureStore),
            secureStore: secureStore,
            engine: relaunched
        )
        await coordinator.recoverNow()
        await relaunched.waitUntilIdle()

        XCTAssertEqual(
            relaunched.mode,
            .paused(.secureStorageUnavailable),
            "a settled endpoint must not be reported with the previous endpoint's credential"
        )
        XCTAssertTrue(relaunchedClient.sentChangeBatches.isEmpty)
        XCTAssertTrue(relaunchedProvider.observedMetrics.isEmpty)
    }

    func testRepeatedRecoveryAfterSettlingIsInert() async throws {
        let secureStore = RecordingSecureStore()
        secureStore.values["destination.endpoint"] = endpoint
        secureStore.values[DestinationCredentialStore.storageKey(for: endpoint)] = token

        defaults.set(true, forKey: "automaticSync.enabled")
        let relaunchedProvider = ScriptedHealthProvider()
        let relaunchedClient = ScriptedSyncClient()
        let relaunched = makeEngine(provider: relaunchedProvider, client: relaunchedClient)
        await relaunched.restorePausedOnSecureStorage()

        let coordinator = makeCoordinator(
            destinationStore: DestinationConfigurationStore(secureStore: secureStore),
            credentialStore: DestinationCredentialStore(secureStore: secureStore),
            secureStore: secureStore,
            engine: relaunched
        )
        await coordinator.recoverNow()
        await relaunched.waitUntilIdle()
        let batchesAfterFirst = relaunchedClient.sentChangeBatches.count
        XCTAssertEqual(secureStore.migrateCallCount, 1, "a converged migration is not repeated")

        await coordinator.recoverNow()
        await relaunched.waitUntilIdle()

        XCTAssertEqual(secureStore.migrateCallCount, 1, "an idempotent re-run skips the keychain write")
        XCTAssertEqual(relaunched.mode, .active)
        XCTAssertEqual(
            relaunchedClient.sentChangeBatches.count,
            batchesAfterFirst,
            "an identical re-report must not duplicate delivery"
        )
    }

    func testMigrationFailureRetriesUntilItSucceedsThenStops() async throws {
        let secureStore = RecordingSecureStore()
        secureStore.values["destination.endpoint"] = endpoint
        secureStore.values[DestinationCredentialStore.storageKey(for: endpoint)] = token
        secureStore.failAllReads = true
        secureStore.migrateFailuresRemaining = 1

        defaults.set(true, forKey: "automaticSync.enabled")
        let relaunchedProvider = ScriptedHealthProvider()
        let relaunched = makeEngine(provider: relaunchedProvider, client: ScriptedSyncClient())
        await relaunched.restorePausedOnSecureStorage()

        let coordinator = makeCoordinator(
            destinationStore: DestinationConfigurationStore(secureStore: secureStore),
            credentialStore: DestinationCredentialStore(secureStore: secureStore),
            secureStore: secureStore,
            engine: relaunched
        )

        // First attempt: the migration fails (a locked keychain) and must be
        // retried by the next trigger, not treated as converged.
        await coordinator.recoverNow()
        XCTAssertEqual(relaunched.mode, .paused(.secureStorageUnavailable))
        XCTAssertEqual(secureStore.migrateCallCount, 1)

        // The device unlocked: the retried migration succeeds, the loads
        // settle, and the engine recovers.
        secureStore.failAllReads = false
        clock.advance(by: 61)
        await coordinator.recoverNow()
        await relaunched.waitUntilIdle()

        XCTAssertEqual(relaunched.mode, .active)
        XCTAssertEqual(secureStore.migrateCallCount, 2)

        // Converged: no further keychain writes.
        await coordinator.recoverNow()
        XCTAssertEqual(secureStore.migrateCallCount, 2)
    }

    // MARK: System notification wiring

    func testProtectedDataAvailableNotificationTriggersRecovery() async throws {
        let secureStore = RecordingSecureStore()
        secureStore.values["destination.endpoint"] = endpoint
        secureStore.values[DestinationCredentialStore.storageKey(for: endpoint)] = token
        secureStore.failAllReads = true

        defaults.set(true, forKey: "automaticSync.enabled")
        let relaunchedProvider = ScriptedHealthProvider()
        let relaunched = makeEngine(provider: relaunchedProvider, client: ScriptedSyncClient())
        await relaunched.restorePausedOnSecureStorage()

        let coordinator = makeCoordinator(
            destinationStore: DestinationConfigurationStore(secureStore: secureStore),
            credentialStore: DestinationCredentialStore(secureStore: secureStore),
            secureStore: secureStore,
            engine: relaunched
        )
        coordinator.start()

        // Unlocking the device posts protectedDataDidBecomeAvailable outside
        // any UI scene; the coordinator must pick it up and settle the stores.
        secureStore.failAllReads = false
        center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)

        await waitFor("engine recovery after the notification") { relaunched.mode == .active }
        await relaunched.waitUntilIdle()
    }
}

/// Keychain stand-in that records accessibility migrations and can fail
/// reads globally or per key.
private final class RecordingSecureStore: SecureValueStoring, @unchecked Sendable {
    var values: [String: String] = [:]
    var failAllReads = false
    var failingKeys: Set<String> = []
    private(set) var migrateCallCount = 0
    /// Simulates a migration that fails (a locked keychain) until cleared.
    var migrateFailuresRemaining = 0

    func readValue(forKey key: String) throws -> String? {
        if failAllReads || failingKeys.contains(key) {
            throw RecoveryStoreError.unavailable
        }
        return values[key]
    }

    func saveValue(_ value: String, forKey key: String) throws {
        values[key] = value
    }

    func removeValue(forKey key: String) throws {
        values.removeValue(forKey: key)
    }

    func migrateToBackgroundAccessibility() throws {
        migrateCallCount += 1
        if migrateFailuresRemaining > 0 {
            migrateFailuresRemaining -= 1
            throw RecoveryStoreError.unavailable
        }
    }

    private enum RecoveryStoreError: Error {
        case unavailable
    }
}
