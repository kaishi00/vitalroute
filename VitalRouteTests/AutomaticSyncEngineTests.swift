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

    /// Spins the main actor until `condition` holds. Race regressions are
    /// asserted by waiting for the state that must appear, never by sleeping
    /// and hoping it did.
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

    private func page(
        additions: [HealthRecord] = [],
        deletions: [DeletedRecord] = [],
        anchor: String?,
        isFull: Bool = false
    ) -> HealthChangePage {
        HealthChangePage(
            additions: additions,
            deletions: deletions,
            anchorData: anchor.map { Data($0.utf8) },
            isFull: isFull
        )
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

        // Bootstrap window is the fixed scope of the DEFAULT depth (7 days).
        XCTAssertEqual(provider.changeQueries.count, 1)
        let query = provider.changeQueries[0]
        XCTAssertNil(query.anchorData)
        XCTAssertEqual(query.metric, .steps)
        XCTAssertEqual(
            query.windowStart.timeIntervalSinceNow,
            -7 * 24 * 3600,
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

    @MainActor
    func testDeeperBackfillRebootstrapsWithWiderWindow() async throws {
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
        _ = await enable(engine)
        await engine.waitUntilIdle()
        XCTAssertEqual(provider.changeQueries.count, 1)
        XCTAssertNil(provider.changeQueries[0].anchorData)

        // Deepening the configured history must mint a fresh scope: the next
        // capture re-bootstraps from the deeper fixed window with no anchor.
        BackfillDepth.store(.allRecords, in: defaults)
        provider.changeQueries.removeAll()
        engine.foregroundCatchUp()
        await engine.waitUntilIdle()

        XCTAssertEqual(provider.changeQueries.count, 1)
        XCTAssertNil(provider.changeQueries[0].anchorData)
        XCTAssertEqual(provider.changeQueries[0].windowStart, .distantPast)

        // The new checkpoint carries the deeper window.
        let checkpoint = await SyncStateStore(directory: tempDirectory).loadCheckpoint(for: .steps)
        XCTAssertEqual(checkpoint?.scope.windowStart, .distantPast)
    }

    @MainActor
    func testShallowerBackfillKeepsExistingScope() async throws {
        BackfillDepth.store(.allRecords, in: defaults)
        let provider = ScriptedHealthProvider()
        provider.script = [
            .steps: [HealthChangePage(
                additions: [record(1)],
                deletions: [],
                anchorData: Data("deep-anchor".utf8),
                isFull: false
            )],
        ]
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()
        XCTAssertEqual(provider.changeQueries[0].windowStart, .distantPast)

        // A shallower preference never discards captured history: the scope
        // keeps its deeper fixed window and continues from its anchor.
        BackfillDepth.store(.sevenDays, in: defaults)
        provider.changeQueries.removeAll()
        engine.foregroundCatchUp()
        await engine.waitUntilIdle()

        XCTAssertEqual(provider.changeQueries.count, 1)
        XCTAssertEqual(provider.changeQueries[0].anchorData, Data("deep-anchor".utf8))
        XCTAssertEqual(provider.changeQueries[0].windowStart, .distantPast)
    }

    @MainActor
    func testThirtyDayDepthShapesBootstrapWindow() async throws {
        BackfillDepth.store(.thirtyDays, in: defaults)
        let provider = ScriptedHealthProvider()
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        XCTAssertEqual(provider.changeQueries.count, 1)
        XCTAssertEqual(
            provider.changeQueries[0].windowStart.timeIntervalSince(
                BackfillDepth.thirtyDays.windowStart(from: Date())
            ),
            0,
            accuracy: 30
        )
    }

    @MainActor
    func testSameDepthSecondPassKeepsScopeAndAnchor() async throws {
        // The everyday case: unchanged depth on a later day must keep the
        // existing scope (its fixed window start is always at-or-earlier
        // than today's desired start) and continue from its anchor.
        let provider = ScriptedHealthProvider()
        provider.script = [
            .steps: [HealthChangePage(
                additions: [record(1)],
                deletions: [],
                anchorData: Data("same-anchor".utf8),
                isFull: false
            )],
        ]
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()
        let firstWindow = provider.changeQueries[0].windowStart

        provider.changeQueries.removeAll()
        engine.foregroundCatchUp()
        await engine.waitUntilIdle()

        XCTAssertEqual(provider.changeQueries.count, 1)
        XCTAssertEqual(provider.changeQueries[0].anchorData, Data("same-anchor".utf8))
        XCTAssertEqual(provider.changeQueries[0].windowStart, firstWindow)
    }

    func testEnabledFlagPersistsAcrossEngineInstances() async throws {
        let provider = ScriptedHealthProvider()
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        let relaunched = makeEngine(provider: ScriptedHealthProvider(), client: ScriptedSyncClient())
        XCTAssertTrue(relaunched.isEnabled)

        await relaunched.disable()
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
        await engine.disable()
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
        XCTAssertNil(engine.nextRetryAt, "the discarded queue owned that retry")
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
        await engine.disable()
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
        XCTAssertNil(engine.nextRetryAt, "an actionable pause schedules no retry")
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
        // Queued changes carry the identity of the destination they were
        // captured for; a real queue is always written by a capture that
        // recorded it first.
        try await SyncStateStore(directory: tempDirectory).savePendingScope(endpoint)

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
        let clock = ClockBox()
        let provider = ScriptedHealthProvider()
        provider.script = [
            .steps: [HealthChangePage(additions: [record(1)], deletions: [], anchorData: Data("a1".utf8), isFull: false)],
        ]
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client, clock: clock)
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
        // The corrupted-anchor pass counted as a transient failure; pass
        // the backoff before the recovery pass.
        clock.advance(by: 61)
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

    func testZombieCatchUpAfterDestinationChangeIsSuppressed() async throws {
        // The regression: a cancelled run with an absorbed trigger must not
        // spawn a successor pass after the destination purge.
        let provider = ScriptedHealthProvider()
        provider.script = [
            .steps: [HealthChangePage(additions: [record(1), record(2)], deletions: [], anchorData: Data("a1".utf8), isFull: false)],
        ]
        let client = ScriptedSyncClient()
        client.sendGate = AsyncGate()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(engine.isRunning)

        // A trigger arrives mid-run (absorbed), then the destination changes.
        engine.foregroundCatchUp()
        await engine.configurationChanged(destination: otherEndpoint, token: token, metrics: [.steps])
        if let gate = client.sendGate { await gate.openAndWait() }
        await engine.waitUntilIdle()
        try await Task.sleep(nanoseconds: 300_000_000)

        let outbox = Outbox(directory: tempDirectory)
        let pending = try await outbox.pendingCount()
        XCTAssertEqual(pending, 0, "no zombie pass may re-append after the purge")
        let checkpoint = await SyncStateStore(directory: tempDirectory).loadCheckpoint(for: .steps)
        XCTAssertNil(checkpoint, "no zombie pass may recreate the checkpoint")
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

    // MARK: Observer completion lifetime

    func testObserverCompletionWaitsForDurableCapture() async throws {
        let provider = ScriptedHealthProvider()
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        provider.script = [.steps: [page(additions: [record(5)], anchor: "c1")]]
        provider.resetConsumption()
        client.resetDelivery()
        provider.captureGate = AsyncGate()

        guard let fired = provider.fireObserver() else {
            return XCTFail("no observer was registered")
        }
        await waitFor("the capture to start") { provider.parkedCaptureCount == 1 }

        XCTAssertEqual(fired.releases.count, 0,
                       "HealthKit must not be answered while the capture is still parked")
        XCTAssertFalse(fired.completion.hasBeenReleased)

        provider.captureGate?.open()
        await waitFor("the completion to be released") { fired.releases.count == 1 }
        await engine.waitUntilIdle()

        XCTAssertEqual(fired.releases.count, 1, "and only once")
        XCTAssertEqual(engine.pendingCount, 0, "the captured change was durable and delivered")
        XCTAssertNotNil(engine.lastDeliveryAt)
    }

    func testObserverCompletionIsReleasedWhileNetworkIsParked() async throws {
        let provider = ScriptedHealthProvider()
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        provider.script = [.steps: [page(additions: [record(6)], anchor: "d1")]]
        provider.resetConsumption()
        client.resetDelivery()
        // The upload parks: durable capture must answer HealthKit anyway.
        client.sendGate = AsyncGate()

        guard let fired = provider.fireObserver() else {
            return XCTFail("no observer was registered")
        }
        await waitFor("the completion to be released while the network is parked") {
            fired.releases.count == 1
        }

        // Durable, not transmitted: the change is in the outbox and the
        // upload has not been acknowledged.
        let queued = try await Outbox(directory: tempDirectory).pendingCount()
        XCTAssertEqual(queued, 1, "the capture preceded the completion")

        client.sendGate?.open()
        await engine.waitUntilIdle()
        XCTAssertEqual(fired.releases.count, 1, "exactly once, even after delivery completes")
        XCTAssertEqual(engine.pendingCount, 0)
    }

    func testObserverCompletionReleasesExactlyOnceWhenCaptureIsCancelled() async throws {
        let provider = ScriptedHealthProvider()
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        provider.script = [.steps: [page(additions: [record(7)], anchor: "e1")]]
        provider.resetConsumption()
        client.resetDelivery()
        provider.captureGate = AsyncGate()

        guard let fired = provider.fireObserver() else {
            return XCTFail("no observer was registered")
        }
        await waitFor("the capture to start") { provider.parkedCaptureCount == 1 }
        XCTAssertEqual(fired.releases.count, 0)

        // Turning automatic sync off mid-capture abandons the capture — and
        // still answers HealthKit, once.
        await engine.disable()
        provider.captureGate?.open()
        await engine.waitUntilIdle()

        XCTAssertEqual(fired.releases.count, 1)
        let queued = try await Outbox(directory: tempDirectory).pendingCount()
        XCTAssertEqual(queued, 0, "the cancelled capture committed nothing")
    }

    func testObserverCompletionReleasesExactlyOnceWhenCaptureFails() async throws {
        let provider = ScriptedHealthProvider()
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        provider.resetConsumption()
        client.resetDelivery()
        provider.changePageError = HealthKitServiceError.unavailable

        guard let fired = provider.fireObserver() else {
            return XCTFail("no observer was registered")
        }
        await waitFor("the completion to be released after a failed capture") {
            fired.releases.count == 1
        }
        await engine.waitUntilIdle()

        XCTAssertEqual(fired.releases.count, 1, "a failed capture still answers HealthKit, exactly once")
        XCTAssertEqual(engine.mode, .active, "an unavailable HealthKit defers rather than pausing")
    }

    func testOverlappingObserverNotificationsEachReleaseExactlyOnce() async throws {
        let provider = ScriptedHealthProvider()
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        provider.script = [.steps: [page(additions: [record(8)], anchor: "f1")]]
        provider.resetConsumption()
        client.resetDelivery()
        provider.captureGate = AsyncGate()

        guard let first = provider.fireObserver() else {
            return XCTFail("no observer was registered")
        }
        await waitFor("the capture to start") { provider.parkedCaptureCount == 1 }

        // Two more notifications arrive while the first capture is in flight.
        guard let second = provider.fireObserver(), let third = provider.fireObserver() else {
            return XCTFail("observer registration was lost")
        }
        XCTAssertEqual(first.releases.count, 0)
        XCTAssertEqual(second.releases.count, 0)
        XCTAssertEqual(third.releases.count, 0)

        provider.captureGate?.open()
        await waitFor("every overlapping notification to be answered") {
            first.releases.count == 1 && second.releases.count == 1 && third.releases.count == 1
        }
        await engine.waitUntilIdle()
        await engine.waitUntilIdle()

        XCTAssertEqual(first.releases.count, 1)
        XCTAssertEqual(second.releases.count, 1)
        XCTAssertEqual(third.releases.count, 1)
        XCTAssertEqual(engine.pendingCount, 0)
    }

    // MARK: Configuration ownership

    func testConfigurationChangeDuringAuthorizationSupersedesEnable() async throws {
        let provider = ScriptedHealthProvider()
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)

        // The user's tap suspends in the HealthKit authorization prompt.
        provider.authorizationGate = AsyncGate()
        let enabling = Task { await engine.enable(destination: endpoint, token: token, metrics: [.steps]) }
        await waitFor("authorization to start") { provider.authorizationRequests == 1 }

        // Meanwhile the destination moves.
        await engine.configurationChanged(destination: otherEndpoint, token: "other-token-0002", metrics: [.sleep])
        provider.authorizationGate?.open()
        let result = await enabling.value

        guard case .failed(let message) = result else {
            return XCTFail("an enable superseded mid-flight must not report success")
        }
        XCTAssertTrue(message.contains("configuration changed"), message)
        XCTAssertFalse(engine.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: "automaticSync.enabled"),
                       "the obsolete enable must not persist the opt-in")
        XCTAssertEqual(client.testConnectionCount, 0,
                       "no capability check may run for a destination the user already replaced")
        XCTAssertTrue(provider.observedMetrics.isEmpty,
                      "no observers may be armed for the obsolete selection")
        XCTAssertTrue(provider.changeQueries.isEmpty)
        XCTAssertTrue(client.sentChangeBatches.isEmpty)
    }

    func testCategoryChangeDuringEnablementSupersedesIt() async throws {
        let provider = ScriptedHealthProvider()
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)

        provider.authorizationGate = AsyncGate()
        let enabling = Task { await engine.enable(destination: endpoint, token: token, metrics: [.steps]) }
        await waitFor("authorization to start") { provider.authorizationRequests == 1 }

        await engine.configurationChanged(destination: endpoint, token: token, metrics: [.sleep])
        provider.authorizationGate?.open()
        let result = await enabling.value

        guard case .failed = result else {
            return XCTFail("expected the enable to be superseded by the category change")
        }
        XCTAssertFalse(engine.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: "automaticSync.enabled"))
        XCTAssertTrue(provider.observedMetrics.isEmpty)
    }

    func testCancelledPassCannotOverwritePurgeWithPause() async throws {
        let provider = ScriptedHealthProvider()
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        provider.script = [.steps: [page(additions: [record(3)], anchor: "g1")]]
        provider.resetConsumption()
        client.resetDelivery()
        provider.captureGate = AsyncGate()

        engine.foregroundCatchUp()
        await waitFor("the pass to park in the capture") { provider.parkedCaptureCount == 1 }

        // The pass ends in an actionable failure at the same moment the user
        // repoints the destination. The purge's disabled state must survive:
        // the stale pass owns nothing any more.
        provider.changePageError = DestinationClientError.authenticationFailed
        let purge = Task {
            await engine.configurationChanged(destination: otherEndpoint, token: token, metrics: [.steps])
        }
        await waitFor("the purge to disable the engine") { !engine.isEnabled }
        provider.captureGate?.open()
        await purge.value
        await engine.waitUntilIdle()

        XCTAssertEqual(engine.mode, .disabled,
                       "a superseded pass must not resurrect a pause over the purge")
        XCTAssertFalse(engine.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: "automaticSync.enabled"),
                       "live state and persisted consent must agree")
    }

    func testDestinationChangeDisablesBeforeAwaitingInFlightWork() async throws {
        let provider = ScriptedHealthProvider()
        provider.script = [.steps: [page(additions: [record(4)], anchor: "h1")]]
        let client = ScriptedSyncClient()
        client.sendGate = AsyncGate()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await waitFor("the enable pass to park in delivery") { client.sentChangeBatches.count == 1 }

        let queriesBefore = provider.changeQueries.count
        let purge = Task {
            await engine.configurationChanged(destination: otherEndpoint, token: token, metrics: [.steps])
        }
        await waitFor("the engine to report disabled") { !engine.isEnabled }
        XCTAssertFalse(defaults.bool(forKey: "automaticSync.enabled"))

        // A trigger arriving while the purge is suspended must find the
        // engine off — no capture may start against the old destination.
        engine.foregroundCatchUp()
        XCTAssertEqual(provider.changeQueries.count, queriesBefore)

        client.sendGate?.open()
        await purge.value
        XCTAssertFalse(engine.isEnabled)
    }

    func testEnableSuspendedInRegistrationIsSupersededByDisable() async throws {
        let provider = ScriptedHealthProvider()
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)

        provider.registrationGate = AsyncGate()
        let enabling = Task { await engine.enable(destination: endpoint, token: token, metrics: [.steps]) }
        await waitFor("registration to start") { provider.registrationAttempts == 1 }

        // The user turns it back off while registration is still suspended.
        await engine.disable()
        provider.registrationGate?.open()
        let result = await enabling.value

        guard case .failed = result else {
            return XCTFail("a superseded enable must not report success")
        }
        XCTAssertFalse(engine.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: "automaticSync.enabled"),
                       "a registration that resumed late must not persist the opt-in")
        XCTAssertTrue(client.sentChangeBatches.isEmpty, "no pass may run for a superseded enable")
        XCTAssertTrue(provider.changeQueries.isEmpty)
    }

    func testDisableAwaitsObserverTeardownBeforeReturning() async throws {
        // The regression: teardown used to be fire-and-forget, so a quick
        // off/on cycle could stop the observers a re-enable had just armed.
        let provider = ScriptedHealthProvider()
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        provider.stopGate = AsyncGate()
        let disabling = Task { await engine.disable() }
        await waitFor("teardown to start") { provider.observationStopCount == 1 }
        XCTAssertFalse(engine.isEnabled)

        // A re-enable issued while teardown is still in flight must land
        // after it, and must leave exactly one live registration.
        provider.registrationGate = AsyncGate()
        let reenabling = Task { await enable(engine) }
        await waitFor("the re-enable to reach registration") { provider.registrationAttempts == 2 }

        provider.stopGate?.open()
        provider.registrationGate?.open()
        await disabling.value
        let result = await reenabling.value
        XCTAssertEqual(result, .enabled)
        await engine.waitUntilIdle()

        XCTAssertTrue(engine.isEnabled)
        XCTAssertEqual(provider.observedMetrics.count, 2, "the re-enable installed one observer set")
    }

    func testSupersededRegistrationDoesNotLeaveObserversArmed() async throws {
        // The regression: a registration that resumed after being superseded
        // left HealthKit armed with nothing owning it, so the app could be
        // woken while automatic sync was off.
        let provider = ScriptedHealthProvider()
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)

        provider.registrationGate = AsyncGate()
        let enabling = Task { await engine.enable(destination: endpoint, token: token, metrics: [.steps]) }
        await waitFor("registration to start") { provider.registrationAttempts == 1 }

        // The selection changes while registration is still suspended. The
        // engine is off and no newer registration is coming, so the observers
        // this attempt armed must be unwound.
        await engine.configurationChanged(destination: endpoint, token: token, metrics: [.sleep])
        provider.registrationGate?.open()
        let result = await enabling.value

        guard case .failed = result else {
            return XCTFail("a superseded enable must not report success")
        }
        XCTAssertFalse(engine.isEnabled)
        XCTAssertEqual(provider.observationStopCount, 1,
                       "observers armed by a superseded registration must not stay armed")
        XCTAssertFalse(defaults.bool(forKey: "automaticSync.enabled"))
        XCTAssertTrue(provider.changeQueries.isEmpty)
    }

    func testAbsorbedCatchUpAfterCredentialReplacementUsesTheNewCredential() async throws {
        // The regression: a trigger absorbed during a pass was dropped when
        // the configuration had moved on, deferring the work to the next
        // unrelated trigger.
        let provider = ScriptedHealthProvider()
        provider.script = [.steps: [page(additions: [record(1)], anchor: "m1")]]
        let client = ScriptedSyncClient()
        client.sendGate = AsyncGate()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await waitFor("the enable pass to park in delivery") { client.sentChangeBatches.count == 1 }

        // More data arrives while the upload is parked, and the user replaces
        // the API key for the same destination.
        provider.script = [.steps: [page(additions: [record(2)], anchor: "m2")]]
        provider.resetConsumption()
        await engine.configurationChanged(destination: endpoint, token: "replaced-token-0003", metrics: [.steps])

        client.sendGate?.open()
        await engine.waitUntilIdle()
        await engine.waitUntilIdle()

        XCTAssertTrue(
            client.sentChangeBatches.contains { $0.authorization.bearerToken == "replaced-token-0003" },
            "the absorbed catch-up must run for the current configuration"
        )
        XCTAssertEqual(engine.pendingCount, 0)
    }

    func testDestinationChangeWhileOffWithNothingQueuedClaimsNoDiscard() async throws {
        let provider = ScriptedHealthProvider()
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)

        await engine.configurationChanged(destination: endpoint, token: token, metrics: [.steps])
        await engine.configurationChanged(destination: otherEndpoint, token: token, metrics: [.steps])

        XCTAssertFalse(engine.isEnabled)
        XCTAssertEqual(engine.lastStatusMessage, "The destination changed while automatic sync was off.",
                       "nothing was queued, so the notice must not claim a discard")
    }

    func testCategoryDisablePurgeIsNotUndoneByAnAbsorbedTrigger() async throws {
        // The regression: a trigger absorbed during a pass let the cancelled
        // run spawn a successor, and that successor drained the outbox
        // generically — with the disabled category's events still in it.
        let provider = ScriptedHealthProvider()
        provider.script = [
            .steps: [page(additions: [record(1)], anchor: "n1")],
            .sleep: [page(additions: [record(2, metric: .sleep)], anchor: "n2")],
        ]
        let client = ScriptedSyncClient()
        client.failNextDelivery(with: .connectionFailed)
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine, metrics: [.steps, .sleep])
        await engine.waitUntilIdle()
        XCTAssertEqual(engine.pendingCount, 2, "both categories are queued")

        provider.script = [:]
        provider.resetConsumption()
        client.resetDelivery()
        provider.captureGate = AsyncGate()

        engine.foregroundCatchUp()
        await waitFor("the pass to park in the capture") { provider.parkedCaptureCount == 1 }
        let sleepQueriesBeforePurge = provider.changeQueries.filter { $0.metric == .sleep }.count

        // A trigger arrives while the pass is in flight and is absorbed.
        // A foreground catch-up is used rather than an observer fire so the
        // claim is recorded synchronously: an observer notification is
        // delivered on its own task and would legitimately start a further
        // pass for the new configuration, which would blur the count below.
        engine.foregroundCatchUp()

        // The user disables one category: its queued data must never upload.
        await engine.configurationChanged(destination: endpoint, token: token, metrics: [.sleep])
        provider.captureGate?.open()
        await engine.waitUntilIdle()
        await engine.waitUntilIdle()

        // The cancelled run must not have spawned a successor: the only pass
        // after these are the purge's own, which runs once the disabled
        // category's events are already gone. A successor would add another
        // capture — and, before the purge's removal landed, could have drained
        // the queue with those events in it.
        let sleepQueriesAfterPurge = provider.changeQueries.filter { $0.metric == .sleep }.count
        XCTAssertEqual(sleepQueriesAfterPurge, sleepQueriesBeforePurge + 1,
                       "only the purge's own pass may run; a successor spawned by the cancelled run would add another")
        let sent = client.sentChangeBatches.flatMap(\.changes)
        XCTAssertFalse(sent.contains { $0.metric == .steps },
                       "the disabled category's queued data must never reach the destination")
        let snapshot = try await Outbox(directory: tempDirectory).nextBatch()
        XCTAssertFalse(snapshot.events.contains { $0.metric == .steps })
        let stepsCheckpoint = await SyncStateStore(directory: tempDirectory).loadCheckpoint(for: .steps)
        XCTAssertNil(stepsCheckpoint)
    }

    func testBackgroundExpirationDoesNotSpawnASuccessorPass() async throws {
        // The regression: dropping the cancelled-run guard let an expired
        // background task start a fresh pass after the system said stop.
        let provider = ScriptedHealthProvider()
        provider.script = [.steps: [page(additions: [record(1)], anchor: "o1")]]
        let client = ScriptedSyncClient()
        client.sendGate = AsyncGate()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await waitFor("the enable pass to park in delivery") { client.sentChangeBatches.count == 1 }

        let queriesBefore = provider.changeQueries.count
        // A trigger arrives, then the background task expires.
        engine.foregroundCatchUp()
        engine.cancelActiveWork()
        client.sendGate?.open()
        await engine.waitUntilIdle()
        await engine.waitUntilIdle()

        XCTAssertEqual(provider.changeQueries.count, queriesBefore,
                       "an expired background task must not start a fresh pass")
        XCTAssertFalse(engine.isRunning)
    }

    func testLostRegistrationRaceIsNotReportedAsAFailure() async throws {
        // One user action is reported through several observable properties,
        // so several reconfigurations race for observer registration. The
        // losers must not pause the engine or claim it is unarmed: the winner
        // owns observation.
        let provider = ScriptedHealthProvider()
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()
        XCTAssertEqual(engine.mode, .active)

        provider.observeError = HealthKitServiceError.registrationSuperseded
        await engine.configurationChanged(destination: endpoint, token: token, metrics: [.steps])
        await engine.waitUntilIdle()

        XCTAssertEqual(engine.mode, .active, "a lost registration race must not pause the engine")
        XCTAssertFalse(
            engine.lastStatusMessage?.contains("observers could not be registered") == true,
            engine.lastStatusMessage ?? ""
        )
        XCTAssertTrue(engine.isEnabled)
    }

    func testUnchangedConfigurationDoesNotReRegisterObservers() async throws {
        // The UI re-reports one change through several observable properties.
        // Those re-reports must not tear down and rebuild background delivery
        // for nothing — and doing so is what made the registration race
        // reachable in the first place.
        let provider = ScriptedHealthProvider()
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()
        let attemptsAfterEnable = provider.registrationAttempts

        await engine.configurationChanged(destination: endpoint, token: token, metrics: [.steps])
        await engine.waitUntilIdle()
        XCTAssertEqual(provider.registrationAttempts, attemptsAfterEnable,
                       "an identical re-report must not churn observation")
        XCTAssertTrue(engine.isEnabled)

        // A credential that must be used stays current without a re-arm.
        await engine.configurationChanged(destination: endpoint, token: "replaced-token-0009", metrics: [.steps])
        await engine.waitUntilIdle()
        XCTAssertEqual(provider.registrationAttempts, attemptsAfterEnable,
                       "a credential-only change must not churn observation")

        // A real change still re-arms.
        await engine.configurationChanged(destination: endpoint, token: "replaced-token-0009", metrics: [.steps, .sleep])
        await engine.waitUntilIdle()
        XCTAssertEqual(provider.registrationAttempts, attemptsAfterEnable + 1,
                       "a changed category set must re-arm observation")
    }

    func testRestoreToleratesALostRegistrationRace() async throws {
        // Launch runs restoration alongside the SwiftUI configuration
        // callbacks, which can share its generation and win the registration
        // race. The restore must not turn that into a pause.
        defaults.set(true, forKey: "automaticSync.enabled")
        let provider = ScriptedHealthProvider()
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)
        // Proves the persisted flag was honoured, so the assertions below
        // cannot pass vacuously.
        XCTAssertTrue(engine.isEnabled)

        provider.observeError = HealthKitServiceError.registrationSuperseded
        await engine.restoreOnLaunch(destination: endpoint, token: token, metrics: [.steps])
        await engine.waitUntilIdle()

        XCTAssertTrue(engine.isEnabled)
        if case .paused(let reason) = engine.mode {
            XCTFail("a lost registration race must not pause restoration: \(reason)")
        }
        XCTAssertFalse(
            engine.lastStatusMessage?.contains("observers could not be registered") == true,
            engine.lastStatusMessage ?? ""
        )
    }

    func testIdenticalReportReArmsWhenObservationIsKnownToBeUnarmed() async throws {
        // The load-bearing safety net on the skip path: an identical
        // re-report must still re-arm if the engine knows observation is not
        // in place.
        let provider = ScriptedHealthProvider()
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        // A changed category set forces a registration attempt, which fails:
        // the engine is then paused and knows observation is not in place.
        provider.observeError = HealthKitServiceError.unavailable
        await engine.configurationChanged(destination: endpoint, token: token, metrics: [.steps, .sleep])
        await engine.waitUntilIdle()
        if case .paused(let reason) = engine.mode {
            XCTAssertTrue(reason.isAutoRecoverable, "\(reason)")
        } else {
            XCTFail("a failed registration must pause recoverably, got \(engine.mode)")
        }
        let attemptsAfterFailure = provider.registrationAttempts

        // Recovery must not depend on the configuration changing.
        provider.observeError = nil
        await engine.configurationChanged(destination: endpoint, token: token, metrics: [.steps, .sleep])
        await engine.waitUntilIdle()

        XCTAssertEqual(provider.registrationAttempts, attemptsAfterFailure + 1,
                       "an unarmed engine must re-register even for an identical report")
        XCTAssertEqual(engine.mode, .active)
    }

    func testDisableClearsTheNextRetryItWasShowing() async throws {
        let provider = ScriptedHealthProvider()
        provider.script = [.steps: [page(additions: [record(1)], anchor: "p1")]]
        let client = ScriptedSyncClient()
        client.failNextDelivery(with: .connectionFailed)
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()
        XCTAssertNotNil(engine.nextRetryAt, "a transient failure arms a retry")

        await engine.disable()

        XCTAssertNil(engine.nextRetryAt, "a disabled engine has no next retry to show")
        XCTAssertFalse(engine.isEnabled)
    }

    // MARK: Destination-bound queue

    func testDestinationChangeWhileDisabledDiscardsQueuedWork() async throws {
        let provider = ScriptedHealthProvider()
        provider.script = [.steps: [page(additions: [record(1), record(2)], anchor: "i1")]]
        let client = ScriptedSyncClient()
        client.failNextDelivery(with: .connectionFailed)
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()
        XCTAssertEqual(engine.pendingCount, 2)

        // Sync is turned off with work still queued, and only then does the
        // destination move. Queued health data must never wait for a new
        // endpoint to become deliverable.
        await engine.disable()
        await engine.configurationChanged(destination: otherEndpoint, token: "other-token-0002", metrics: [.steps])

        XCTAssertFalse(engine.isEnabled)
        XCTAssertEqual(engine.pendingCount, 0)
        let checkpoint = await SyncStateStore(directory: tempDirectory).loadCheckpoint(for: .steps)
        XCTAssertNil(checkpoint)
        XCTAssertTrue(engine.lastStatusMessage?.contains("discarded") == true,
                      engine.lastStatusMessage ?? "")
    }

    func testQueueCapturedForAnotherDestinationIsNeverDelivered() async throws {
        let provider = ScriptedHealthProvider()
        provider.script = [.steps: [page(additions: [record(1)], anchor: "j1")]]
        let client = ScriptedSyncClient()
        client.failNextDelivery(with: .connectionFailed)
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()
        let queued = try await Outbox(directory: tempDirectory).pendingCount()
        XCTAssertEqual(queued, 1)
        client.resetDelivery()
        // The relaunch captures the new destination's own window.
        provider.script = [.steps: [page(additions: [record(2)], anchor: "j2")]]
        provider.resetConsumption()

        // The app terminates here. On relaunch the destination is different —
        // the change happened while it was not running, so no in-session
        // purge ever saw it.
        let relaunched = makeEngine(provider: provider, client: client)
        await relaunched.restoreOnLaunch(
            destination: otherEndpoint,
            token: "other-token-0002",
            metrics: [.steps]
        )
        await relaunched.waitUntilIdle()

        // The queued change captured for the old destination is discarded;
        // only work captured for the new one is ever sent to it.
        let delivered = client.sentChangeBatches.flatMap(\.changes)
        XCTAssertEqual(delivered, [.upsert(record(2))],
                       "queued health data must never reach a destination it was not captured for")
        XCTAssertEqual(relaunched.pendingCount, 0)
        let checkpoint = await SyncStateStore(directory: tempDirectory).loadCheckpoint(for: .steps)
        XCTAssertEqual(checkpoint?.scope.destination, otherEndpoint,
                       "the surviving checkpoint belongs to the new destination's own window")
        XCTAssertTrue(relaunched.lastStatusMessage?.contains("different destination") == true,
                      relaunched.lastStatusMessage ?? "")
    }

    // MARK: Reporting

    func testBackgroundRetrySubmissionFailureIsSurfaced() async throws {
        let provider = ScriptedHealthProvider()
        provider.script = [.steps: [page(additions: [record(1)], anchor: "k1")]]
        let client = ScriptedSyncClient()
        client.failNextDelivery(with: .connectionFailed)
        let engine = makeEngine(provider: provider, client: client)
        // iOS refuses the request (too many pending requests, or an
        // unpermitted identifier): the status line must not imply a wake-up
        // is armed.
        engine.scheduleBackgroundRetry = { _ in false }

        _ = await enable(engine)
        await engine.waitUntilIdle()

        XCTAssertEqual(engine.pendingCount, 1)
        XCTAssertTrue(
            engine.lastStatusMessage?.contains("did not accept a background retry request") == true,
            engine.lastStatusMessage ?? ""
        )
    }

    func testBackgroundRetryIsReportedAsScheduledWhenAccepted() async throws {
        let provider = ScriptedHealthProvider()
        provider.script = [.steps: [page(additions: [record(1)], anchor: "l1")]]
        let client = ScriptedSyncClient()
        client.failNextDelivery(with: .connectionFailed)
        let engine = makeEngine(provider: provider, client: client)
        engine.scheduleBackgroundRetry = { _ in true }

        _ = await enable(engine)
        await engine.waitUntilIdle()

        XCTAssertTrue(
            engine.lastStatusMessage?.contains("retry is scheduled with backoff") == true,
            engine.lastStatusMessage ?? ""
        )
    }

    func testWhitespaceOnlyCredentialIsNotACredential() async throws {
        let engine = makeEngine(provider: ScriptedHealthProvider(), client: ScriptedSyncClient())

        let result = await engine.enable(destination: endpoint, token: "  \n\t ", metrics: [.steps])

        XCTAssertEqual(result, .failed(message: AutomaticSyncPauseReason.credentialMissing.userMessage))
        XCTAssertFalse(engine.isEnabled)
    }

    func testWhitespaceOnlyCredentialChangePausesInsteadOfSending() async throws {
        let provider = ScriptedHealthProvider()
        let client = ScriptedSyncClient()
        let engine = makeEngine(provider: provider, client: client)
        _ = await enable(engine)
        await engine.waitUntilIdle()

        await engine.configurationChanged(destination: endpoint, token: "   ", metrics: [.steps])

        XCTAssertEqual(engine.mode, .paused(.credentialMissing),
                       "a whitespace-only key must not be used as a credential")
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

/// Counts releases of an observer completion. Lock-backed because the
/// release closure runs wherever the release happens, not on the main actor.
private final class ReleaseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

/// Scripted health provider: pages are consumed in order per metric, and
/// observer notifications can be fired on demand.
@MainActor
private final class ScriptedHealthProvider: HealthDataProviding {
    struct RecordedQuery {
        let metric: HealthMetric
        let anchorData: Data?
        let windowStart: Date
    }

    /// One fired notification: the completion the app must release, and a
    /// counter of how many times it was actually released.
    struct FiredNotification {
        let completion: ObserverCompletion
        let releases: ReleaseCounter
    }

    var script: [HealthMetric: [HealthChangePage]] = [:]
    private var consumed: [HealthMetric: Int] = [:]

    /// Simulates a relaunch replaying the same pages.
    func resetConsumption() {
        consumed.removeAll()
    }
    var changeQueries: [RecordedQuery] = []
    private(set) var observedMetrics: [Set<HealthMetric>] = []
    private(set) var observationStopCount = 0
    private(set) var authorizationRequests = 0
    private(set) var registrationAttempts = 0
    /// Incremented each time a capture page parks on `captureGate`.
    private(set) var parkedCaptureCount = 0
    private(set) var firedNotifications: [FiredNotification] = []
    /// When set, change queries throw this instead of paging.
    var storageWriteError: Error?
    /// When set, change queries throw this before recording.
    var changePageError: Error?
    /// When set, observeChanges throws.
    var observeError: Error?
    /// Parks authorization, so a configuration change can land mid-enable.
    var authorizationGate: AsyncGate?
    /// Parks observer registration.
    var registrationGate: AsyncGate?
    /// Parks a capture page, so tests can inspect state while a capture is
    /// genuinely in flight.
    var captureGate: AsyncGate?
    /// Parks observer teardown.
    var stopGate: AsyncGate?

    private var observerHandler: (@Sendable (ObserverCompletion) -> Void)?

    var isAvailable: Bool { true }

    func requestReadAuthorization(for metrics: Set<HealthMetric>) async throws {
        authorizationRequests += 1
        if let authorizationGate {
            await authorizationGate.enter()
        }
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
        if let captureGate {
            parkedCaptureCount += 1
            await captureGate.enter()
        }
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
        handler: @escaping @Sendable (ObserverCompletion) -> Void
    ) async throws {
        registrationAttempts += 1
        if let observeError {
            throw observeError
        }
        if let registrationGate {
            await registrationGate.enter()
        }
        observedMetrics.append(metrics)
        observerHandler = handler
    }

    func stopObservingChanges() async {
        observationStopCount += 1
        if let stopGate {
            await stopGate.enter()
        }
        observerHandler = nil
    }

    /// Fires one notification the way HealthKit would: the app receives an
    /// exactly-once completion whose releases are counted, so a test can
    /// prove the engine neither answers early nor answers twice.
    @discardableResult
    func fireObserver() -> FiredNotification? {
        guard let observerHandler else { return nil }
        let releases = ReleaseCounter()
        let completion = ObserverCompletion { releases.increment() }
        let fired = FiredNotification(completion: completion, releases: releases)
        firedNotifications.append(fired)
        observerHandler(completion)
        return fired
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
        handler: @escaping @Sendable (ObserverCompletion) -> Void
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
