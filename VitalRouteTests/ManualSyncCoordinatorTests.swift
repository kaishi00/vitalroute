import XCTest
@testable import VitalRoute

final class ManualSyncCoordinatorTests: XCTestCase {
    private let endpoint = "https://health.example.org/v1/records"
    private let token = "coordinator-test-token-0001"

    private var suites: [(defaults: UserDefaults, name: String)] = []

    override func tearDown() {
        for suite in suites {
            suite.defaults.removePersistentDomain(forName: suite.name)
        }
        suites.removeAll()
        super.tearDown()
    }

    private func record(_ index: Int, metric: HealthMetric = .steps, start: TimeInterval = 0) -> HealthRecord {
        HealthRecord(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
            metric: metric,
            value: Double(index),
            unit: "count",
            startDate: Date(timeIntervalSince1970: 1_735_689_600 + start),
            endDate: Date(timeIntervalSince1970: 1_735_689_600 + start + 60)
        )
    }

    @MainActor
    private func makeCoordinator(
        provider: StubHealthDataProvider,
        client: StubDestinationClient,
        defaults: UserDefaults? = nil
    ) -> ManualSyncCoordinator {
        ManualSyncCoordinator(
            healthData: provider,
            client: client,
            defaults: defaults ?? makeDefaults()
        )
    }

    private func makeDefaults() -> UserDefaults {
        let name = "sync-coordinator-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        suites.append((defaults, name))
        return defaults
    }

    @MainActor
    private func waitForCompletion(_ coordinator: ManualSyncCoordinator) async {
        while coordinator.isSyncing {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    // MARK: Happy path

    @MainActor
    func testSuccessfulSyncReportsCountsAndPersistsLastSync() async throws {
        let provider = StubHealthDataProvider(export: [record(1), record(2)])
        let client = StubDestinationClient()
        let defaults = makeDefaults()
        let coordinator = makeCoordinator(provider: provider, client: client, defaults: defaults)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps, .sleep])
        await waitForCompletion(coordinator)

        XCTAssertEqual(coordinator.lastOutcome?.result, .completed)
        let summary = coordinator.lastOutcome?.summary
        XCTAssertEqual(summary?.recordsFound, 2)
        XCTAssertEqual(summary?.batchesPlanned, 1)
        XCTAssertEqual(summary?.batchesDelivered, 1)
        XCTAssertEqual(summary?.acceptedRecords, 2)
        XCTAssertNotNil(coordinator.lastSuccessfulSync)
        XCTAssertEqual(coordinator.lastSuccessfulSync?.deliveredRecords, summary?.deliveredRecords)

        // Authorization was requested for exactly the selected categories.
        XCTAssertEqual(provider.authorizationRequestedMetrics, [.sleep, .steps])
        // The export query used the same categories.
        XCTAssertEqual(provider.exportedMetrics, [.sleep, .steps])

        // Persisted across a new coordinator instance.
        let reloaded = ManualSyncCoordinator(healthData: provider, client: client, defaults: defaults)
        XCTAssertEqual(reloaded.lastSuccessfulSync, coordinator.lastSuccessfulSync)
    }

    @MainActor
    func testEmptyWindowCompletesWithoutSendingAnything() async throws {
        let provider = StubHealthDataProvider(export: [])
        let client = StubDestinationClient()
        let coordinator = makeCoordinator(provider: provider, client: client)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        await waitForCompletion(coordinator)

        XCTAssertEqual(coordinator.lastOutcome?.result, .completed)
        XCTAssertEqual(coordinator.lastOutcome?.summary.recordsFound, 0)
        XCTAssertEqual(client.sentPayloads.count, 0)
    }

    @MainActor
    func testRecordsAreBatchedAtTheConfiguredSize() async throws {
        let records = (0..<SyncLimits.recordsPerUploadBatch + 50).map { record($0) }
        let provider = StubHealthDataProvider(export: records)
        let client = StubDestinationClient()
        let coordinator = makeCoordinator(provider: provider, client: client)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        await waitForCompletion(coordinator)

        XCTAssertEqual(client.sentPayloads.count, 2)
        XCTAssertEqual(client.sentPayloads[0].records.count, SyncLimits.recordsPerUploadBatch)
        XCTAssertEqual(client.sentPayloads[1].records.count, 50)
        // Batches preserve the deterministic ascending record order.
        XCTAssertEqual(client.sentPayloads[0].records.first?.id, records.first?.id)
        XCTAssertEqual(client.sentPayloads[1].records.last?.id, records.last?.id)
        XCTAssertEqual(coordinator.lastOutcome?.result, .completed)
        XCTAssertEqual(coordinator.lastOutcome?.summary.acceptedRecords, records.count)
    }

    // MARK: Truncation

    @MainActor
    func testTruncatedExportIsNeverReportedAsComplete() async throws {
        let provider = StubHealthDataProvider(export: [record(1)], truncated: [.heartRate])
        let client = StubDestinationClient()
        let coordinator = makeCoordinator(provider: provider, client: client)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.heartRate, .steps])
        await waitForCompletion(coordinator)

        guard case .truncated(let metrics)? = coordinator.lastOutcome?.result else {
            XCTFail("expected truncated outcome, got \(String(describing: coordinator.lastOutcome?.result))")
            return
        }
        XCTAssertEqual(metrics, [.heartRate])
        // Delivered data is still reported, but no success marker is written.
        XCTAssertNil(coordinator.lastSuccessfulSync)
        XCTAssertEqual(coordinator.lastOutcome?.summary.deliveredRecords, 1)
    }

    @MainActor
    func testExportWindowIsSnapshotPinned() async throws {
        let provider = StubHealthDataProvider(export: [record(1)])
        let client = StubDestinationClient()
        let coordinator = makeCoordinator(provider: provider, client: client)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps], now: now)
        await waitForCompletion(coordinator)

        XCTAssertEqual(provider.exportQueryWindows.count, 1)
        let window = provider.exportQueryWindows[0]
        XCTAssertEqual(window.end, now)
        // Default depth (7 days) shapes the manual window.
        XCTAssertEqual(
            window.start.timeIntervalSince(BackfillDepth.sevenDays.windowStart(from: now)),
            0,
            accuracy: 1
        )
    }

    @MainActor
    func testManualPlanHonorsAllRecordsDepth() async throws {
        let provider = StubHealthDataProvider(export: [])
        let client = StubDestinationClient()
        let defaults = makeDefaults()
        BackfillDepth.store(.allRecords, in: defaults)
        let coordinator = makeCoordinator(provider: provider, client: client, defaults: defaults)

        let now = Date()
        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps], now: now)
        await waitForCompletion(coordinator)

        XCTAssertEqual(provider.exportQueryWindows.count, 1)
        XCTAssertEqual(provider.exportQueryWindows[0].start, .distantPast)
        XCTAssertEqual(provider.exportQueryWindows[0].end, now)
    }

    @MainActor
    func testEmptyWindowSyncStillCountsAsSuccessful() async throws {
        // A completed sync that found nothing is a success: it confirms the
        // selected categories had no records in the window, and updates the
        // last-success marker with zero counts.
        let provider = StubHealthDataProvider(export: [])
        let client = StubDestinationClient()
        let defaults = makeDefaults()
        let coordinator = makeCoordinator(provider: provider, client: client, defaults: defaults)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        await waitForCompletion(coordinator)

        XCTAssertEqual(coordinator.lastOutcome?.result, .completed)
        XCTAssertEqual(coordinator.lastSuccessfulSync?.deliveredRecords, 0)
    }

    // MARK: Preflight

    @MainActor
    func testMissingTokenFailsWithoutTouchingHealthOrNetwork() async {
        let provider = StubHealthDataProvider(export: [record(1)])
        let client = StubDestinationClient()
        let coordinator = makeCoordinator(provider: provider, client: client)

        coordinator.startSync(endpoint: endpoint, token: nil, metrics: [.steps])

        XCTAssertFalse(coordinator.isSyncing)
        XCTAssertEqual(client.sentPayloads.count, 0)
        XCTAssertEqual(provider.authorizationCount, 0)
        guard case .failed(let message)? = coordinator.lastOutcome?.result else {
            XCTFail("expected failure outcome")
            return
        }
        XCTAssertTrue(message.contains("API key"))
    }

    @MainActor
    func testEmptySelectionFailsPreflight() async {
        let provider = StubHealthDataProvider(export: [record(1)])
        let client = StubDestinationClient()
        let coordinator = makeCoordinator(provider: provider, client: client)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [])

        guard case .failed(let message)? = coordinator.lastOutcome?.result else {
            XCTFail("expected failure outcome")
            return
        }
        XCTAssertTrue(message.contains("at least one category"))
        XCTAssertEqual(client.sentPayloads.count, 0)
    }

    @MainActor
    func testInvalidEndpointFailsPreflight() async {
        let provider = StubHealthDataProvider(export: [record(1)])
        let client = StubDestinationClient()
        let coordinator = makeCoordinator(provider: provider, client: client)

        coordinator.startSync(endpoint: "http://insecure.example.org", token: token, metrics: [.steps])

        guard case .failed(let message)? = coordinator.lastOutcome?.result else {
            XCTFail("expected failure outcome")
            return
        }
        XCTAssertTrue(message.contains("HTTPS"))
        XCTAssertEqual(client.sentPayloads.count, 0)
    }

    // MARK: Overlap and snapshot consistency

    @MainActor
    func testOverlappingSyncIsIgnoredWhileOneRuns() async throws {
        let provider = StubHealthDataProvider(export: [record(1)])
        let gate = AsyncGate()
        let client = StubDestinationClient()
        client.sendGate = gate
        let coordinator = makeCoordinator(provider: provider, client: client)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        // Wait until the first sync is parked inside the client send.
        await gate.waitForEntry()
        XCTAssertTrue(coordinator.isSyncing)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.sleep])
        // Second call is a no-op: still exactly one operation in flight.

        await gate.open()
        await waitForCompletion(coordinator)

        XCTAssertEqual(client.sentPayloads.count, 1)
    }

    @MainActor
    func testConfigurationChangeDoesNotRedirectAnUnderwaySync() async throws {
        let provider = StubHealthDataProvider(export: [record(1), record(2)])
        let gate = AsyncGate()
        let client = StubDestinationClient()
        client.sendGate = gate
        let coordinator = makeCoordinator(provider: provider, client: client)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        await gate.waitForEntry()

        // The user changes everything mid-flight: endpoint, credential, and
        // selection. The underway operation keeps its captured snapshot.
        let otherClient = StubDestinationClient()
        coordinator.startSync(endpoint: "https://other.example.org/v1/records", token: "other", metrics: [.sleep])
        await gate.open()
        await waitForCompletion(coordinator)

        XCTAssertEqual(client.sentPayloads.count, 1)
        XCTAssertEqual(otherClient.sentPayloads.count, 0)
        XCTAssertEqual(client.receivedAuthorizations.map(\.bearerToken), [token])
        XCTAssertEqual(client.receivedEndpoints, [URL(string: endpoint)!])
        XCTAssertEqual(client.sentPayloads[0].records.count, 2)
    }

    // MARK: Failure and cancellation

    @MainActor
    func testMidBatchFailureReportsPartialProgressNotSuccess() async throws {
        let records = (0..<450).map { record($0) } // 3 batches at 200/200/50
        let provider = StubHealthDataProvider(export: records)
        let client = StubDestinationClient()
        client.failOnBatchNumber = 2
        client.failure = .serverRejected(status: 500)
        let coordinator = makeCoordinator(provider: provider, client: client)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        await waitForCompletion(coordinator)

        XCTAssertEqual(client.sentPayloads.count, 2)
        guard case .failed(let message)? = coordinator.lastOutcome?.result else {
            XCTFail("expected failure outcome")
            return
        }
        XCTAssertTrue(message.contains("HTTP 500"))
        let summary = coordinator.lastOutcome?.summary
        XCTAssertEqual(summary?.batchesDelivered, 1)
        XCTAssertEqual(summary?.deliveredRecords, 200)
        XCTAssertEqual(summary?.batchesPlanned, 3)
        XCTAssertNil(coordinator.lastSuccessfulSync)
    }

    @MainActor
    func testAuthFailureBeforeAnyUploadFailsCleanly() async throws {
        let provider = StubHealthDataProvider(export: [record(1)], shouldFailAuthorization: true)
        let client = StubDestinationClient()
        let coordinator = makeCoordinator(provider: provider, client: client)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        await waitForCompletion(coordinator)

        XCTAssertEqual(client.sentPayloads.count, 0)
        guard case .failed = coordinator.lastOutcome?.result else {
            XCTFail("expected failure outcome")
            return
        }
    }

    @MainActor
    func testCancellationBetweenBatchesReportsCancelledWithPartialCounts() async throws {
        let records = (0..<450).map { record($0) }
        let provider = StubHealthDataProvider(export: records)
        let gate = AsyncGate()
        let client = StubDestinationClient()
        client.sendGate = gate
        let coordinator = makeCoordinator(provider: provider, client: client)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        // Cancel once batch 1 has entered the client; the gate keeps the
        // task alive long enough for the cancellation to be observable.
        await gate.waitForEntry()
        coordinator.cancelSync()
        await gate.open()
        await waitForCompletion(coordinator)

        XCTAssertEqual(coordinator.lastOutcome?.result, .cancelled)
        XCTAssertLessThanOrEqual(coordinator.lastOutcome!.summary.batchesDelivered, 1)
        XCTAssertNil(coordinator.lastSuccessfulSync)
        // The engine's manual-sync hook observes phase returning to .idle;
        // pin it on the cancellation path too, not just on success.
        XCTAssertEqual(coordinator.phase, .idle)
    }

    @MainActor
    func testCancellingWhileQueuedBehindTheGateClearsTheSyncState() async throws {
        // The regression: `runSync`'s cleanup never ran when the cancellation
        // landed while the task was still queued behind the work gate, so the
        // in-flight marker stayed set and manual sync could never start again.
        let gate = SyncWorkGate()
        let sendGate = AsyncGate()

        let holderClient = StubDestinationClient()
        holderClient.sendGate = sendGate
        let holder = ManualSyncCoordinator(
            healthData: StubHealthDataProvider(export: [record(1)]),
            client: holderClient,
            defaults: makeDefaults(),
            workGate: gate
        )
        let queuedClient = StubDestinationClient()
        // A non-empty export, so "nothing was uploaded" is not vacuous, and
        // the provider's counters below prove `runSync` was never entered.
        let queuedProvider = StubHealthDataProvider(export: [record(99)])
        let queued = ManualSyncCoordinator(
            healthData: queuedProvider,
            client: queuedClient,
            defaults: makeDefaults(),
            workGate: gate
        )

        // The first sync takes the gate and parks inside its upload.
        holder.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        await sendGate.waitForEntry()

        // The second queues behind it, then the user cancels.
        queued.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        XCTAssertTrue(queued.isSyncing)
        queued.cancelSync()

        await sendGate.open()
        await waitForCompletion(holder)

        // The queued run never entered; it must still stop reporting as
        // syncing once the gate is released.
        var attempts = 0
        while queued.isSyncing && attempts < 250 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
            attempts += 1
        }

        XCTAssertFalse(queued.isSyncing, "a cancellation while queued must not wedge manual sync")
        XCTAssertEqual(queued.phase, .idle)
        XCTAssertEqual(queuedClient.sentPayloads.count, 0, "the cancelled run must not have uploaded")
        XCTAssertEqual(queuedProvider.authorizationCount, 0, "the cancelled run was never entered")
        guard case .cancelled? = queued.lastOutcome?.result else {
            return XCTFail(
                "a queued cancellation must be reported as cancelled, got \(String(describing: queued.lastOutcome?.result))"
            )
        }

        // And the coordinator is usable again.
        queued.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        await waitForCompletion(queued)
        XCTAssertEqual(queued.lastOutcome?.result, .completed)
    }

    @MainActor
    func testRetryAfterFailureIsUserInitiatedOnly() async throws {
        // A failed sync leaves no residual task: the next startSync runs.
        let provider = StubHealthDataProvider(export: [record(1)])
        let client = StubDestinationClient()
        client.failure = .connectionFailed
        let coordinator = makeCoordinator(provider: provider, client: client)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        await waitForCompletion(coordinator)
        XCTAssertFalse(coordinator.isSyncing)

        client.failure = nil
        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        await waitForCompletion(coordinator)

        XCTAssertEqual(client.sentPayloads.count, 2)
        XCTAssertEqual(coordinator.lastOutcome?.result, .completed)
        XCTAssertNotNil(coordinator.lastSuccessfulSync)
    }
}

// MARK: - Test doubles

@MainActor
private final class StubHealthDataProvider: HealthDataProviding {
    let exportRecords: [HealthRecord]
    let truncated: Set<HealthMetric>
    let shouldFailAuthorization: Bool
    private(set) var authorizationCount = 0
    private(set) var authorizationRequestedMetrics: [HealthMetric] = []
    private(set) var exportedMetrics: [HealthMetric] = []
    private(set) var exportQueryWindows: [(start: Date, end: Date)] = []

    init(
        export records: [HealthRecord],
        truncated: Set<HealthMetric> = [],
        shouldFailAuthorization: Bool = false
    ) {
        self.exportRecords = records
        self.truncated = truncated
        self.shouldFailAuthorization = shouldFailAuthorization
    }

    var isAvailable: Bool { true }

    func requestReadAuthorization(for metrics: Set<HealthMetric>) async throws {
        authorizationCount += 1
        authorizationRequestedMetrics.append(contentsOf: metrics.sorted { $0.rawValue < $1.rawValue })
        if shouldFailAuthorization {
            throw HealthKitServiceError.authorizationFailed
        }
    }

    func queryRecentRecords(
        since startDate: Date,
        metrics: Set<HealthMetric>,
        perMetricLimit: Int
    ) async throws -> [HealthRecord] {
        exportRecords.filter { metrics.contains($0.metric) }
    }

    func exportRecords(
        since startDate: Date,
        through endDate: Date,
        metrics: Set<HealthMetric>
    ) async throws -> HealthExportResult {
        exportedMetrics.append(contentsOf: metrics.sorted { $0.rawValue < $1.rawValue })
        exportQueryWindows.append((startDate, endDate))
        return HealthExportResult(
            records: exportRecords.filter { metrics.contains($0.metric) },
            truncatedMetrics: truncated
        )
    }

    func changePage(
        for metric: HealthMetric,
        since anchorData: Data?,
        windowStart: Date,
        limit: Int
    ) async throws -> HealthChangePage {
        HealthChangePage(
            additions: [],
            deletions: [],
            anchorData: anchorData,
            isFull: false
        )
    }

    func observeChanges(
        for metrics: Set<HealthMetric>,
        handler: @escaping @Sendable (ObserverCompletion) -> Void
    ) async throws {}

    func stopObservingChanges() async {}
}

private final class StubDestinationClient: DestinationClient, @unchecked Sendable {
    private(set) var sentPayloads: [SyncPayload] = []
    private(set) var receivedEndpoints: [URL] = []
    private(set) var receivedAuthorizations: [DestinationAuthorization] = []

    /// When set, the send parked on this gate before returning.
    var sendGate: AsyncGate?
    /// 1-based batch number that should throw `failure` instead of acking.
    var failOnBatchNumber: Int?
    var failure: DestinationClientError?

    func send(
        _ payload: SyncPayload,
        to endpoint: URL,
        authorization: DestinationAuthorization
    ) async throws -> SyncAcknowledgment {
        let batchNumber = sentPayloads.count + 1
        sentPayloads.append(payload)
        receivedEndpoints.append(endpoint)
        receivedAuthorizations.append(authorization)

        if let gate = sendGate {
            await gate.enter()
        }
        if failOnBatchNumber == batchNumber, let failure {
            throw failure
        }
        return SyncAcknowledgment(accepted: payload.records.count, duplicates: 0)
    }

    func testConnection(
        to endpoint: URL,
        authorization: DestinationAuthorization
    ) async throws -> ReceiverHealthResponse {
        ReceiverHealthResponse(
            status: "ok",
            service: "vitalroute-receiver",
            apiVersion: 1,
            capabilities: []
        )
    }

    func sendChanges(
        _ changes: [SyncChangeEvent],
        batchID: UUID,
        to endpoint: URL,
        authorization: DestinationAuthorization
    ) async throws -> ChangeAcknowledgment {
        ChangeAcknowledgment(
            accepted: changes.count,
            duplicates: 0,
            superseded: 0,
            appliedDeletions: 0,
            duplicateDeletions: 0
        )
    }
}

/// A one-shot gate that lets tests pause an async operation at a known point.
private actor AsyncGate {
    private var entered = false
    private var opened = false

    func enter() async {
        entered = true
        while !opened {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    var isEntered: Bool {
        entered
    }

    func waitForEntry() async {
        while !entered {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func open() {
        opened = true
    }
}
