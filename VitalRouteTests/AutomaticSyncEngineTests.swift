import XCTest
@testable import VitalRoute

/// Deterministic engine tests with scripted health/client doubles, real
/// file-backed outbox and state stores in temp directories, and a
/// controllable clock. These tests exercise lifecycle, incremental capture,
/// durable recovery windows, configuration policies, backpressure, backoff,
/// and serialization.
@MainActor
final class AutomaticSyncEngineTests: XCTestCase {
    private var tempDirectory: URL!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    private let endpoint = "https://health.example.org/v1/records"
    private let token = "engine-test-token-0001"
    private let otherEndpoint = "https://other.example.org/v1/records"

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vitalroute-engine-tests-\(UUID().uuidString)")
        defaultsSuiteName = "engine-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    // MARK: Fixtures

    private func makeEngine(
        provider: ScriptedHealthProvider,
        client: ScriptedSyncClient,
        clock: ClockBox = ClockBox(),
        gate: SyncWorkGate = SyncWorkGate()
    ) -> AutomaticSyncEngine {
        AutomaticSyncEngine(
            healthData: provider,
            client: client,
            stateStore: SyncStateStore(directory: tempDirectory),
            outbox: Outbox(directory: tempDirectory),
            workGate: gate,
            defaults: defaults,
            now: { clock.now }
        )
    }

    private func record(_ id: Int, metric: HealthMetric = .steps) -> HealthRecord {
        HealthRecord(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            metric: metric,
            value: Double(id),
            unit: "count",
            startDate: Date(timeIntervalSince1970: 1_735_689_600),
            endDate: Date(timeIntervalSince1970: 1_735_689_660)
        )
    }

    private func deletion(_ id: Int, metric: HealthMetric = .steps) -> DeletedRecord {
        DeletedRecord(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            metric: metric,
            startDate: Date(timeIntervalSince1970: 1_735_689_600),
            endDate: Date(timeIntervalSince1970: 1_735_689_660)
        )
    }

    @discardableResult
    private func enable(_ engine: AutomaticSyncEngine, metrics: Set<HealthMetric> = [.steps]) async -> AutomaticSyncEnableResult {
        await engine.enable(destination: endpoint, token: token, metrics: metrics)
    }

    // MARK: Lifecycle

    func testEnableRequiresPrerequisites() async {
        let engine = makeEngine(provider: ScriptedHealthProvider(), client: ScriptedSyncClient())

        let noMetrics = await engine.enable(destination: endpoint, token: token, metrics: [])
        XCTAssertEqual(noMetrics, .failed(message: AutomaticSyncPauseReason.selectionEmpty.userMessage))

        let noToken = await engine.enable(destination: endpoint, token: nil, metrics: [.steps])
        XCTAssertEqual(noToken, .failed(message: AutomaticSyncPauseReason.credentialMissing.userMessage))

        let badEndpoint = await engine.enable(destination: "http://insecure.example.org", token: token, metrics: [.steps])
        guard case .failed = badEndpoint else {
            return XCTFail("expected failure")
        }
        XCTAssertFalse(engine.isEnabled)
    }

    func testEnableRequiresDeletionCapableReceiver() async {
        let client = ScriptedSyncClient()
        client.healthResponse = ReceiverHealthResponse(
            status: "ok", service: "vitalroute-receiver", apiVersion: 1, capabilities: []
        )
        let provider = ScriptedHealthProvider()
        let engine = makeEngine(provider: provider, client: client)

        let result = await enable(engine)

        guard case .failed(let message) = result else {
            return XCTFail("expected failure for v1 receiver")
        }
        XCTAssertTrue(message.contains("does not support deletions"))
        XCTAssertFalse(engine.isEnabled)
        XCTAssertEqual(provider.observedMetrics.count, 0)
        // A v1 receiver must never receive a v2 change batch.
        XCTAssertEqual(client.sentChangeBatches.count, 0)
    }

    func testEnableRegistersObserversRequestsAuthorizationAndBootstraps() async throws {
        let provider = ScriptedHealthProvider()
        provider.script = [
            .steps: [HealthChangePage(
                additions: [record(1)],
                deletions: [],
                anchorData: Data("a1".utf8),
                isFull: false
            )],
        ]
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)

        let result = await enable(engine)
        XCTAssertEqual(result, .enabled)
        await engine.waitUntilIdle()

        XCTAssertTrue(engine.isEnabled)
        XCTAssertEqual(provider.observedMetrics, [[.steps]])
        XCTAssertEqual(provider.authorizationRequests, 1)
        XCTAssertEqual(client.testConnectionCount, 1)

        // Bootstrap window is the fixed seven-day scope.
        XCTAssertEqual(provider.changeQueries.count, 1)
        let query = provider.changeQueries[0]
        XCTAssertNil(query.anchorData)
        XCTAssertEqual(query.metric, .steps)
        XCTAssertEqual(
            query.windowStart.timeIntervalSinceNow,
            -Double(BackgroundSyncLimits.bootstrapWindowDays * 24 * 3600),
            accuracy: 30
        )

        // Captured, delivered, checkpointed.
        XCTAssertEqual(client.sentChangeBatches.count, 1)
        XCTAssertEqual(client.sentChangeBatches[0].changes, [.upsert(record(1))])
        XCTAssertEqual(engine.pendingCount, 0)
        XCTAssertNotNil(engine.lastDeliveryAt)

        let checkpoint = await SyncStateStore(directory: tempDirectory).loadCheckpoint(for: .steps)
        XCTAssertEqual(checkpoint?.anchorData, Data("a1".utf8))
        XCTAssertEqual(checkpoint?.scope.destination, endpoint)
    }

    func testEnabledFlagPersistsAcrossEngineInstances() async throws {
        let provider = ScriptedHealthProvider()
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        let relaunched = makeEngine(provider: ScriptedHealthProvider(), client: ScriptedSyncClient())
        XCTAssertTrue(relaunched.isEnabled)

        relaunched.disable()
        XCTAssertFalse(relaunched.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: "automaticSync.enabled"))
    }

    func testDisableStopsObserversAndWork() async throws {
        let provider = ScriptedHealthProvider()
        let client = ScriptedSyncClient()
        client.sendGate = AsyncGate()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        provider.script = [
            .steps: [HealthChangePage(additions: [record(2)], deletions: [], anchorData: Data("a2".utf8), isFull: false)],
        ]
        client.resetDelivery()
        engine.foregroundCatchUp()
        try await Task.sleep(nanoseconds: 50_000_000)
        engine.disable()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(provider.observationStopCount, 1)
        XCTAssertFalse(engine.isEnabled)
        await engine.waitUntilIdle()
    }

    func testRestoreOnLaunchReRegistersObserversWithoutUserInteraction() async throws {
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: ScriptedHealthProvider(), client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        // Simulated relaunch: a fresh engine reading the persisted flag.
        let relaunchedProvider = ScriptedHealthProvider()
        let relaunched = makeEngine(provider: relaunchedProvider, client: ScriptedSyncClient())
        await relaunched.restoreOnLaunch(destination: endpoint, token: token, metrics: [.steps])
        await relaunched.waitUntilIdle()

        XCTAssertEqual(relaunchedProvider.observedMetrics, [[.steps]])
        XCTAssertEqual(relaunchedProvider.authorizationRequests, 0, "launch restoration must not prompt")
    }

    // MARK: Incremental capture

    func testDeletionOnlyPageQueuesDeleteEvents() async throws {
        let provider = ScriptedHealthProvider()
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        provider.script = [
            .steps: [HealthChangePage(
                additions: [],
                deletions: [deletion(7)],
                anchorData: Data("a2".utf8),
                isFull: false
            )],
        ]
        provider.resetConsumption()
        client.resetDelivery()
        engine.foregroundCatchUp()
        await engine.waitUntilIdle()

        XCTAssertEqual(client.sentChangeBatches.count, 1)
        XCTAssertEqual(client.sentChangeBatches[0].changes, [.delete(deletion(7))])
        XCTAssertEqual(engine.pendingCount, 0)
    }

    func testIncrementalQueriesResumeFromPersistedAnchor() async throws {
        let provider = ScriptedHealthProvider()
        provider.script = [
            .steps: [
                HealthChangePage(additions: [record(1)], deletions: [], anchorData: Data("a1".utf8), isFull: false),
                HealthChangePage(additions: [], deletions: [deletion(1)], anchorData: Data("a2".utf8), isFull: false),
            ],
        ]
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        // The persisted anchor resumes the stream: the second query starts
        // from where the first page ended, and the deletion is delivered.
        client.resetDelivery()
        engine.foregroundCatchUp()
        await engine.waitUntilIdle()

        XCTAssertEqual(provider.changeQueries.map(\.anchorData), [nil, Data("a1".utf8)])
        XCTAssertEqual(client.sentChangeBatches.count, 1)
        XCTAssertEqual(client.sentChangeBatches[0].changes, [.delete(deletion(1))])
    }

    func testPageBudgetStopsMidStreamAndNextPassResumes() async throws {
        let provider = ScriptedHealthProvider()
        provider.script = [
            .steps: (0..<100).map { index in
                HealthChangePage(
                    additions: [record(index + 1)],
                    deletions: [],
                    anchorData: Data("a\(index)".utf8),
                    isFull: true
                )
            },
        ]
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        // The pass stops at the page budget; the checkpoint is the anchor of
        // the last completed page.
        XCTAssertEqual(provider.changeQueries.count, BackgroundSyncLimits.pagesPerCategoryPerPass)
        let budget = BackgroundSyncLimits.pagesPerCategoryPerPass
        let lastAnchor = Data("a\(budget - 1)".utf8)
        let checkpoint = await SyncStateStore(directory: tempDirectory).loadCheckpoint(for: .steps)
        XCTAssertEqual(checkpoint?.anchorData, lastAnchor)

        // The next pass resumes from the persisted mid-stream anchor.
        client.resetDelivery()
        engine.foregroundCatchUp()
        await engine.waitUntilIdle()
        XCTAssertEqual(provider.changeQueries.count, budget * 2)
        XCTAssertEqual(provider.changeQueries[budget].anchorData, lastAnchor)
    }

    func testScopeMismatchRebootstrapsWithFreshGeneration() async throws {
        let provider = ScriptedHealthProvider()
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()
        let firstScope = await SyncStateStore(directory: tempDirectory).loadCheckpoint(for: .steps)?.scope

        // The category is disabled (checkpoint cleared) and re-enabled.
        await engine.configurationChanged(destination: endpoint, token: token, metrics: [.sleep])
        await engine.configurationChanged(destination: endpoint, token: token, metrics: [.steps])

        provider.script = [.steps: [HealthChangePage(additions: [record(9)], deletions: [], anchorData: Data("b1".utf8), isFull: false)]]
        client.resetDelivery()
        engine.foregroundCatchUp()
        await engine.waitUntilIdle()

        // Re-enablement bootstraps from scratch: nil anchor, new generation.
        let bootstrapQuery = provider.changeQueries.first { $0.metric == .steps && $0.anchorData == nil }
        XCTAssertNotNil(bootstrapQuery)
        let newScope = await SyncStateStore(directory: tempDirectory).loadCheckpoint(for: .steps)?.scope
        XCTAssertEqual(newScope?.destination, firstScope?.destination)
        XCTAssertNotEqual(newScope?.generation, firstScope?.generation)
    }

    // MARK: Configuration policies

    func testDestinationChangeDisablesAndDiscardsPendingWithNotice() async throws {
        let provider = ScriptedHealthProvider()
        provider.script = [
            .steps: [HealthChangePage(additions: [record(1), record(2)], deletions: [], anchorData: Data("a1".utf8), isFull: false)],
        ]
        let client = ScriptedSyncClient()
        client.failNextDelivery(with: .connectionFailed)
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        // Two events pending after a delivery failure.
        XCTAssertEqual(engine.pendingCount, 2)

        await engine.configurationChanged(destination: otherEndpoint, token: token, metrics: [.steps])

        XCTAssertFalse(engine.isEnabled)
        let pendingAfterChange = engine.pendingCount
        XCTAssertEqual(pendingAfterChange, 0, "pending work for the old destination must be discarded")
        let checkpoint = await SyncStateStore(directory: tempDirectory).loadCheckpoint(for: .steps)
        XCTAssertNil(checkpoint, "checkpoints must not move to the new destination")
        XCTAssertTrue(
            engine.lastStatusMessage?.contains("discarded") == true,
            "user must see the discard notice: \(engine.lastStatusMessage ?? "")"
        )
        XCTAssertEqual(provider.observationStopCount, 1)
        XCTAssertEqual(client.sentChangeBatches.filter { $0.endpoint.absoluteString == otherEndpoint }.count, 0,
                       "nothing may ever be sent to the new destination from this event")
    }

    func testCategoryDisablePreventsItsQueuedDataUpload() async throws {
        let provider = ScriptedHealthProvider()
        provider.script = [
            .steps: [HealthChangePage(additions: [record(1)], deletions: [], anchorData: Data("s1".utf8), isFull: false)],
            .sleep: [HealthChangePage(additions: [record(2, metric: .sleep)], deletions: [], anchorData: Data("z1".utf8), isFull: false)],
        ]
        let client = ScriptedSyncClient()
        client.failNextDelivery(with: .connectionFailed)
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine, metrics: [.steps, .sleep])
        await engine.waitUntilIdle()
        XCTAssertEqual(engine.pendingCount, 2)

        // Disable the sleep category.
        await engine.configurationChanged(destination: endpoint, token: token, metrics: [.steps])
        await engine.waitUntilIdle()

        let snapshot = try await Outbox(directory: tempDirectory).nextBatch()
        XCTAssertEqual(snapshot.totalPending, 1)
        XCTAssertEqual(snapshot.events.first?.metric, .steps)
        let sleepCheckpoint = await SyncStateStore(directory: tempDirectory).loadCheckpoint(for: .sleep)
        XCTAssertNil(sleepCheckpoint)
    }

    func testCredentialReplacementKeepsPendingAndUsesNewToken() async throws {
        let provider = ScriptedHealthProvider()
        provider.script = [
            .steps: [HealthChangePage(additions: [record(1)], deletions: [], anchorData: Data("a1".utf8), isFull: false)],
        ]
        let client = ScriptedSyncClient()
        client.failNextDelivery(with: .authenticationFailed)
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        // Authentication failure pauses actionably; pending is kept.
        XCTAssertEqual(engine.mode, .paused(.authenticationFailed))
        XCTAssertEqual(engine.pendingCount, 1)

        // The user replaces the credential for the SAME destination; the
        // pause is actionable so the user re-enables.
        engine.disable()
        client.resetDelivery()
        provider.script = [:]
        _ = await engine.enable(destination: endpoint, token: "replaced-token-0002", metrics: [.steps])
        await engine.waitUntilIdle()

        XCTAssertEqual(engine.pendingCount, 0, "pending work survives credential replacement")
        XCTAssertEqual(client.sentChangeBatches.count, 1)
        XCTAssertEqual(client.sentChangeBatches[0].authorization.bearerToken, "replaced-token-0002")
    }

    // MARK: Failure recovery

    func testCrashReplayAfterAppendBeforeCheckpointDeduplicates() async throws {
        let clock = ClockBox()
        // First engine: appends events, then delivery fails and the
        // checkpoint "crash window" is simulated.
        let provider = ScriptedHealthProvider()
        provider.script = [
            .steps: [HealthChangePage(additions: [record(1)], deletions: [], anchorData: Data("a1".utf8), isFull: false)],
        ]
        let client = ScriptedSyncClient()
        client.failNextDelivery(with: .connectionFailed)
        let engine = makeEngine(provider: provider, client: client, clock: clock)
        _ = await enable(engine)
        await engine.waitUntilIdle()
        XCTAssertEqual(engine.pendingCount, 1)
        let outbox = Outbox(directory: tempDirectory)
        let pendingBeforeReplay = try await outbox.pendingCount()
        XCTAssertEqual(pendingBeforeReplay, 1)

        // Simulate the crash window: the checkpoint file was never written.
        await SyncStateStore(directory: tempDirectory).clearCheckpoint(for: .steps)

        // Relaunch replays the same page; dedupe leaves one event.
        provider.script = [
            .steps: [HealthChangePage(additions: [record(1)], deletions: [], anchorData: Data("a1".utf8), isFull: false)],
        ]
        provider.resetConsumption()
        client.resetDelivery()
        clock.advance(by: 61)
        engine.foregroundCatchUp()
        await engine.waitUntilIdle()

        let pendingAfterReplay = try await outbox.pendingCount()
        XCTAssertEqual(pendingAfterReplay, 0)
        XCTAssertEqual(client.sentChangeBatches.count, 1)
        XCTAssertEqual(client.sentChangeBatches[0].changes, [.upsert(record(1))])
    }

    func testServerCommitWithLostResponseThenRetrySucceeds() async throws {
        let clock = ClockBox()
        let provider = ScriptedHealthProvider()
        provider.script = [
            .steps: [HealthChangePage(additions: [record(1)], deletions: [], anchorData: Data("a1".utf8), isFull: false)],
        ]
        let client = ScriptedSyncClient()
        // The server commits but the response is lost.
        client.failNextDelivery(with: .connectionFailed)
        let engine = makeEngine(provider: provider, client: client, clock: clock)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        XCTAssertEqual(engine.pendingCount, 1, "unacknowledged work stays queued")
        XCTAssertNotNil(engine.nextRetryAt, "a retry must be scheduled with backoff")

        // After the backoff elapses, the retry is answered idempotently.
        clock.advance(by: 61)
        client.resetDelivery()
        client.nextAcknowledgment = ChangeAcknowledgment(
            accepted: 0, duplicates: 1, superseded: 0, appliedDeletions: 0, duplicateDeletions: 0
        )
        engine.backgroundTaskFired()
        await engine.waitUntilIdle()

        XCTAssertEqual(engine.pendingCount, 0)
        XCTAssertEqual(engine.lastStatusMessage, nil)
    }

    func testTransientFailureBacksOffAndSkipsEarlyRetries() async throws {
        let clock = ClockBox()
        let provider = ScriptedHealthProvider()
        provider.script = [
            .steps: [HealthChangePage(additions: [record(1)], deletions: [], anchorData: Data("a1".utf8), isFull: false)],
        ]
        let client = ScriptedSyncClient()
        client.failNextDelivery(with: .connectionFailed)
        let engine = makeEngine(provider: provider, client: client, clock: clock)
        _ = await enable(engine)
        await engine.waitUntilIdle()
        XCTAssertEqual(engine.mode, .active, "transient failures must not pause")
        XCTAssertEqual(engine.pendingCount, 1)

        client.resetDelivery()
        engine.foregroundCatchUp()
        await engine.waitUntilIdle()
        XCTAssertEqual(client.sentChangeBatches.count, 0, "delivery must be skipped inside the backoff window")

        // After the backoff elapses, delivery proceeds.
        clock.advance(by: 61)
        engine.foregroundCatchUp()
        await engine.waitUntilIdle()
        XCTAssertEqual(client.sentChangeBatches.count, 1)
        XCTAssertEqual(engine.pendingCount, 0)
    }

    func testActionableFailuresDoNotRetryEndlessly() async throws {
        let provider = ScriptedHealthProvider()
        provider.script = [
            .steps: [HealthChangePage(additions: [record(1)], deletions: [], anchorData: Data("a1".utf8), isFull: false)],
        ]
        let client = ScriptedSyncClient()
        client.failNextDelivery(with: .authenticationFailed)
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        XCTAssertEqual(engine.mode, .paused(.authenticationFailed))

        client.resetDelivery()
        engine.foregroundCatchUp()
        engine.backgroundTaskFired()
        await engine.waitUntilIdle()
        XCTAssertEqual(client.sentChangeBatches.count, 0, "an actionable pause must not hammer the receiver")
        XCTAssertEqual(engine.mode, .paused(.authenticationFailed))
        XCTAssertEqual(engine.pendingCount, 1)
    }

    func testUnreconciledAcknowledgmentIsActionable() async throws {
        let provider = ScriptedHealthProvider()
        provider.script = [
            .steps: [HealthChangePage(additions: [record(1), record(2)], deletions: [], anchorData: Data("a1".utf8), isFull: false)],
        ]
        let client = ScriptedSyncClient()
        // The real client reconciles acknowledgment counts and throws
        // malformedAcknowledgment on a mismatch; the engine must treat that
        // as an actionable protocol failure, not retry it endlessly.
        client.failNextDelivery(with: .malformedAcknowledgment)
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        XCTAssertEqual(engine.mode, .paused(.protocolFailure("the destination acknowledged batches in an unexpected format.")))
        XCTAssertEqual(engine.pendingCount, 2)
    }

    func testBackpressureStopsQueriesAndKeepsDraining() async throws {
        let provider = ScriptedHealthProvider()
        let client = ScriptedSyncClient()
        client.failNextDelivery(with: .connectionFailed)
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        // Fill the outbox to capacity directly (e.g. built up while offline).
        let outbox = Outbox(directory: tempDirectory)
        try await outbox.prepare()
        var events: [SyncChangeEvent] = []
        for index in 0..<Outbox.capacityLimit {
            events.append(.upsert(record(index + 1)))
        }
        _ = try await outbox.append(events)

        let queriesBefore = provider.changeQueries.count
        client.resetDelivery()
        engine.foregroundCatchUp()
        await engine.waitUntilIdle()

        XCTAssertEqual(provider.changeQueries.count, queriesBefore, "no capture at capacity")
        XCTAssertEqual(engine.mode, .paused(.queueAtCapacity))
        XCTAssertTrue(client.sentChangeBatches.count > 0, "delivery keeps draining")

        // Drain everything: capacity pause is auto-recoverable.
        let drained = try await outbox.pendingCount()
        for _ in 0..<(drained / Outbox.deliveryBatchSize + 1) {
            let snapshot = try await outbox.nextBatch()
            if snapshot.events.isEmpty { break }
            await outbox.remove(eventIDs: snapshot.events.map(\.eventID))
        }
        engine.foregroundCatchUp()
        await engine.waitUntilIdle()
        XCTAssertEqual(engine.mode, .active)
    }

    func testLockedStorageDefersInsteadOfPausing() async throws {
        let provider = ScriptedHealthProvider()
        provider.storageWriteError = CocoaError(.fileWriteUnknown)
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)

        // Storage failures surface during the enable pass's capture phase.
        _ = await enable(engine)
        await engine.waitUntilIdle()

        XCTAssertEqual(engine.mode, .active, "deferred is not a pause")
        XCTAssertTrue(engine.lastStatusMessage?.contains("deferred") == true,
                      "\(engine.lastStatusMessage ?? "")")
        XCTAssertEqual(client.sentChangeBatches.count, 0)
    }

    // MARK: Concurrency and absorption

    func testObserverFiringDuringActiveRunIsAbsorbedIntoOneCatchUp() async throws {
        let provider = ScriptedHealthProvider()
        let client = ScriptedSyncClient()
        client.sendGate = AsyncGate()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        provider.script = [
            .steps: [HealthChangePage(additions: [record(1)], deletions: [], anchorData: Data("a1".utf8), isFull: false)],
        ]
        provider.resetConsumption()
        client.resetDelivery()
        engine.foregroundCatchUp()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(engine.isRunning)

        // Changes arrive mid-run: two observer fires are absorbed.
        provider.fireObserver()
        provider.fireObserver()
        if let gate = client.sendGate { await gate.openAndWait() }

        await engine.waitUntilIdle()
        XCTAssertEqual(client.sentChangeBatches.count, 1, "the in-flight run delivers once")

        // Exactly one absorbed catch-up pass follows.
        await engine.waitUntilIdle()
        let totalDeliveries = client.sentChangeBatches.count
        XCTAssertEqual(totalDeliveries, 1, "the absorbed catch-up found nothing new to deliver")
        XCTAssertEqual(engine.pendingCount, 0)
    }

    func testCorruptedAnchorClearsCheckpointAndRebootstraps() async throws {
        let provider = ScriptedHealthProvider()
        provider.script = [
            .steps: [HealthChangePage(additions: [record(1)], deletions: [], anchorData: Data("a1".utf8), isFull: false)],
        ]
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()
        let firstScope = await SyncStateStore(directory: tempDirectory).loadCheckpoint(for: .steps)?.scope

        // The stored anchor becomes unreadable (e.g. OS format change).
        let store = SyncStateStore(directory: tempDirectory)
        try await store.prepare()
        try await store.save(CategoryCheckpoint(
            scope: firstScope!,
            anchorData: Data("garbage".utf8),
            updatedAt: Date()
        ))

        provider.changePageError = HealthKitServiceError.corruptedAnchor
        engine.foregroundCatchUp()
        await engine.waitUntilIdle()
        let cleared = await SyncStateStore(directory: tempDirectory).loadCheckpoint(for: .steps)
        XCTAssertNil(cleared, "the unreadable checkpoint must be dropped")

        // The next pass bootstraps fresh: nil anchor, new generation.
        provider.changePageError = nil
        provider.resetConsumption()
        client.resetDelivery()
        provider.script = [
            .steps: [HealthChangePage(additions: [record(2)], deletions: [], anchorData: Data("b1".utf8), isFull: false)],
        ]
        engine.foregroundCatchUp()
        await engine.waitUntilIdle()
        let newScope = await SyncStateStore(directory: tempDirectory).loadCheckpoint(for: .steps)?.scope
        XCTAssertNotEqual(newScope?.generation, firstScope?.generation)
        XCTAssertEqual(client.sentChangeBatches.count, 1)
    }

    func testDestinationChangeDuringParkedDeliveryNeverLeaksToNewDestination() async throws {
        let provider = ScriptedHealthProvider()
        provider.script = [
            .steps: [HealthChangePage(additions: [record(1), record(2)], deletions: [], anchorData: Data("a1".utf8), isFull: false)],
        ]
        let client = ScriptedSyncClient()
        client.sendGate = AsyncGate()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        // The enable pass parks inside delivery with the old destination's
        // events captured and the checkpoint already advanced.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(engine.isRunning)

        // The user changes the destination mid-flight.
        await engine.configurationChanged(destination: otherEndpoint, token: token, metrics: [.steps])
        if let gate = client.sendGate { await gate.openAndWait() }
        await engine.waitUntilIdle()

        XCTAssertFalse(engine.isEnabled)
        let outbox = Outbox(directory: tempDirectory)
        let pending = try await outbox.pendingCount()
        XCTAssertEqual(pending, 0, "old-destination events must be discarded, never re-pointed")
        // Nothing was ever sent anywhere for this run: the parked send was
        // cancelled before its ack could remove anything.
        let delivered = client.sentChangeBatches
        XCTAssertEqual(delivered.filter { $0.endpoint.absoluteString == otherEndpoint }.count, 0)
    }

    func testHTTP429IsTransientNotActionable() {
        let classification = AutomaticSyncEngine.classify(
            DestinationClientError.serverRejected(status: 429)
        )
        XCTAssertEqual(classification, .transient)
        let actionable = AutomaticSyncEngine.classify(
            DestinationClientError.serverRejected(status: 400)
        )
        XCTAssertEqual(actionable, .actionable(.protocolFailure("the destination returned HTTP 400.")))
    }

    func testEnableFailsVisiblyWhenObserversCannotBeRegistered() async throws {
        let provider = ScriptedHealthProvider()
        provider.observeError = HealthKitServiceError.unavailable
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)

        let result = await enable(engine)

        guard case .failed(let message) = result else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(message.contains("observers could not be registered"))
        XCTAssertFalse(engine.isEnabled)
        XCTAssertNotNil(engine.lastStatusMessage)
        XCTAssertEqual(client.sentChangeBatches.count, 0, "no pass may run without observers")
    }

    func testManualAndAutomaticWorkSerializeThroughTheGate() async throws {
        let gate = SyncWorkGate()
        let provider = ScriptedHealthProvider()
        provider.script = [
            .steps: [HealthChangePage(additions: [record(1)], deletions: [], anchorData: Data("a1".utf8), isFull: false)],
        ]
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client, gate: gate)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        // A manual sync with one record parks inside its send, holding the
        // shared gate.
        let manualProvider = ManualStubHealthProvider()
        manualProvider.records = [record(1)]
        let manualClient = ManualStubClient()
        manualClient.sendGate = AsyncGate()
        let manual = ManualSyncCoordinator(
            healthData: manualProvider,
            client: manualClient,
            defaults: defaults,
            workGate: gate
        )
        manual.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(manual.isSyncing)

        // The automatic pass must wait, not overlap.
        provider.script = [
            .steps: [HealthChangePage(additions: [record(2)], deletions: [], anchorData: Data("a2".utf8), isFull: false)],
        ]
        provider.resetConsumption()
        client.resetDelivery()
        engine.foregroundCatchUp()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(client.sentChangeBatches.count, 0, "automatic delivery waits for the manual run")
        XCTAssertEqual(provider.changeQueries.filter { $0.anchorData == Data("a1".utf8) }.count, 0,
                       "automatic capture waits too")

        if let gate = manualClient.sendGate { await gate.openAndWait() }
        while manual.isSyncing {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await engine.waitUntilIdle()
        XCTAssertEqual(client.sentChangeBatches.count, 1)
    }

    func testCancellationMidDeliveryPreservesPending() async throws {
        let provider = ScriptedHealthProvider()
        provider.script = [
            .steps: [HealthChangePage(additions: [record(1), record(2)], deletions: [], anchorData: Data("a1".utf8), isFull: false)],
        ]
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        // New work arrives; its delivery is parked, then the run is
        // cancelled mid-delivery.
        client.resetDelivery()
        client.sendGate = AsyncGate()
        provider.script = [
            .steps: [HealthChangePage(additions: [record(3), record(4)], deletions: [], anchorData: Data("a3".utf8), isFull: false)],
        ]
        provider.resetConsumption()
        engine.foregroundCatchUp()
        try await Task.sleep(nanoseconds: 100_000_000)
        engine.cancelActiveWork()
        if let gate = client.sendGate { await gate.openAndWait() }
        await engine.waitUntilIdle()

        XCTAssertEqual(engine.pendingCount, 2, "cancellation preserves undelivered work")
        let checkpoint = await SyncStateStore(directory: tempDirectory).loadCheckpoint(for: .steps)
        XCTAssertNotNil(checkpoint, "the captured checkpoint stays advanced; the outbox holds the work")
    }

    // MARK: Observer handler contract

    func testObserverHandlerCompletesPromptlyWithoutWaitingOnNetwork() async throws {
        let provider = ScriptedHealthProvider()
        let client = ScriptedSyncClient()
        client.sendGate = AsyncGate()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        provider.script = [
            .steps: [HealthChangePage(additions: [record(1)], deletions: [], anchorData: Data("a9".utf8), isFull: false)],
        ]
        provider.resetConsumption()
        client.resetDelivery()

        // The observer callback returns immediately even with the network
        // parked: bounded work happens off the callback.
        let start = ContinuousClock.now
        provider.fireObserver()
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .milliseconds(500))

        if let gate = client.sendGate { await gate.openAndWait() }
        await engine.waitUntilIdle()
        XCTAssertEqual(client.sentChangeBatches.count, 1)
    }
}

// MARK: - Test doubles

/// A mutable, real-time-backed clock the tests can advance for backoff.
final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return Date().addingTimeInterval(offset)
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        offset += seconds
        lock.unlock()
    }
}

/// Scripted health provider: pages are consumed in order per metric.
@MainActor
private final class ScriptedHealthProvider: HealthDataProviding {
    struct RecordedQuery {
        let metric: HealthMetric
        let anchorData: Data?
        let windowStart: Date
    }

    var script: [HealthMetric: [HealthChangePage]] = [:]
    private var consumed: [HealthMetric: Int] = [:]

    /// Simulates a relaunch replaying the same pages.
    func resetConsumption() {
        consumed.removeAll()
    }
    private(set) var changeQueries: [RecordedQuery] = []
    private(set) var observedMetrics: [Set<HealthMetric>] = []
    private(set) var observationStopCount = 0
    private(set) var authorizationRequests = 0
    /// When set, change queries throw this instead of paging.
    var storageWriteError: Error?
    /// When set, change queries throw this before recording.
    var changePageError: Error?
    /// When set, observeChanges throws.
    var observeError: Error?

    private var observerHandler: (@Sendable () -> Void)?

    var isAvailable: Bool { true }

    func requestReadAuthorization(for metrics: Set<HealthMetric>) async throws {
        authorizationRequests += 1
    }

    func queryRecentRecords(
        since startDate: Date,
        metrics: Set<HealthMetric>,
        perMetricLimit: Int
    ) async throws -> [HealthRecord] {
        []
    }

    func exportRecords(
        since startDate: Date,
        through endDate: Date,
        metrics: Set<HealthMetric>
    ) async throws -> HealthExportResult {
        HealthExportResult(records: [], truncatedMetrics: [])
    }

    func changePage(
        for metric: HealthMetric,
        since anchorData: Data?,
        windowStart: Date,
        limit: Int
    ) async throws -> HealthChangePage {
        if let changePageError {
            throw changePageError
        }
        if let storageWriteError {
            throw storageWriteError
        }
        changeQueries.append(RecordedQuery(metric: metric, anchorData: anchorData, windowStart: windowStart))
        let pages = script[metric] ?? []
        let index = consumed[metric] ?? 0
        consumed[metric, default: 0] = index + 1
        guard index < pages.count else {
            return HealthChangePage(additions: [], deletions: [], anchorData: anchorData, isFull: false)
        }
        return pages[index]
    }

    func observeChanges(
        for metrics: Set<HealthMetric>,
        handler: @escaping @Sendable () -> Void
    ) async throws {
        if let observeError {
            throw observeError
        }
        observedMetrics.append(metrics)
        observerHandler = handler
    }

    func stopObservingChanges() async {
        observationStopCount += 1
        observerHandler = nil
    }

    func fireObserver() {
        observerHandler?()
    }
}

/// Scripted client with capability, delivery scripting, and gating.
private final class ScriptedSyncClient: DestinationClient, @unchecked Sendable {
    struct SentBatch {
        let changes: [SyncChangeEvent]
        let batchID: UUID
        let endpoint: URL
        let authorization: DestinationAuthorization
    }

    private let lock = NSLock()
    private var storage: [SentBatch] = []
    private var connections = 0

    var testConnectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections
    }
    /// Synchronous lock accessor: NSLock must not be touched lexically
    /// inside async functions (an error under Swift 6 concurrency).
    var sentChangeBatches: [SentBatch] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var healthResponse = ReceiverHealthResponse(
        status: "ok", service: "vitalroute-receiver", apiVersion: 2,
        capabilities: ["additions", "deletions"]
    )
    var nextAcknowledgment: ChangeAcknowledgment?
    var sendGate: AsyncGate?
    private var queuedFailure: DestinationClientError?
    private var failureForThisSend: DestinationClientError?

    func failNextDelivery(with error: DestinationClientError) {
        performLocked { queuedFailure = error }
    }

    /// Clears delivery history without forgetting the queued failure
    /// semantics used across enable/pass boundaries in a test.
    func resetDelivery() {
        performLocked { storage.removeAll() }
    }

    private func performLocked(_ body: () -> Void) {
        lock.lock()
        body()
        lock.unlock()
    }

    func send(
        _ payload: SyncPayload,
        to endpoint: URL,
        authorization: DestinationAuthorization
    ) async throws -> SyncAcknowledgment {
        SyncAcknowledgment(accepted: payload.records.count, duplicates: 0)
    }

    func testConnection(
        to endpoint: URL,
        authorization: DestinationAuthorization
    ) async throws -> ReceiverHealthResponse {
        performLocked { connections += 1 }
        return healthResponse
    }

    func sendChanges(
        _ changes: [SyncChangeEvent],
        batchID: UUID,
        to endpoint: URL,
        authorization: DestinationAuthorization
    ) async throws -> ChangeAcknowledgment {
        performLocked {
            storage.append(SentBatch(
                changes: changes, batchID: batchID, endpoint: endpoint, authorization: authorization
            ))
        }

        if let gate = sendGate {
            await gate.enter()
            try Task.checkCancellation()
        }
        performLocked {
            failureForThisSend = queuedFailure
            queuedFailure = nil
        }
        if let failure = failureForThisSend {
            failureForThisSend = nil
            throw failure
        }
        if let nextAcknowledgment {
            return nextAcknowledgment
        }
        let upserts = changes.filter { if case .upsert = $0 { return true } else { return false } }.count
        return ChangeAcknowledgment(
            accepted: upserts,
            duplicates: 0,
            superseded: 0,
            appliedDeletions: changes.count - upserts,
            duplicateDeletions: 0
        )
    }
}

@MainActor
private final class ManualStubHealthProvider: HealthDataProviding {
    var records: [HealthRecord] = []
    var isAvailable: Bool { true }

    func requestReadAuthorization(for metrics: Set<HealthMetric>) async throws {}

    func queryRecentRecords(
        since startDate: Date,
        metrics: Set<HealthMetric>,
        perMetricLimit: Int
    ) async throws -> [HealthRecord] {
        []
    }

    func exportRecords(
        since startDate: Date,
        through endDate: Date,
        metrics: Set<HealthMetric>
    ) async throws -> HealthExportResult {
        HealthExportResult(records: records, truncatedMetrics: [])
    }

    func changePage(
        for metric: HealthMetric,
        since anchorData: Data?,
        windowStart: Date,
        limit: Int
    ) async throws -> HealthChangePage {
        HealthChangePage(additions: [], deletions: [], anchorData: anchorData, isFull: false)
    }

    func observeChanges(
        for metrics: Set<HealthMetric>,
        handler: @escaping @Sendable () -> Void
    ) async throws {}

    func stopObservingChanges() async {}
}

private final class ManualStubClient: DestinationClient, @unchecked Sendable {
    var sendGate: AsyncGate?

    func send(
        _ payload: SyncPayload,
        to endpoint: URL,
        authorization: DestinationAuthorization
    ) async throws -> SyncAcknowledgment {
        if let sendGate {
            await sendGate.enter()
        }
        return SyncAcknowledgment(accepted: 0, duplicates: 0)
    }

    func testConnection(
        to endpoint: URL,
        authorization: DestinationAuthorization
    ) async throws -> ReceiverHealthResponse {
        ReceiverHealthResponse(status: "ok", service: "vitalroute-receiver", apiVersion: 2, capabilities: ["additions", "deletions"])
    }

    func sendChanges(
        _ changes: [SyncChangeEvent],
        batchID: UUID,
        to endpoint: URL,
        authorization: DestinationAuthorization
    ) async throws -> ChangeAcknowledgment {
        ChangeAcknowledgment(accepted: 0, duplicates: 0, superseded: 0, appliedDeletions: 0, duplicateDeletions: 0)
    }
}

/// One-shot async gate used to park scripted deliveries.
private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false

    private var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }

    func enter() async {
        while !isOpen && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func open() {
        lock.lock()
        opened = true
        lock.unlock()
    }

    func openAndWait() async {
        open()
    }
}
