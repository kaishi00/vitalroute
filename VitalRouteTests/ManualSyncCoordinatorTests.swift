import XCTest
@testable import VitalRoute

final class ManualSyncCoordinatorTests: XCTestCase {
    private let endpoint = "https://health.example.org/v1/records"
    private let token = "coordinator-test-token-0001"

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

        gate.open()
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
        gate.open()
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
        gate.open()
        await waitForCompletion(coordinator)

        XCTAssertEqual(coordinator.lastOutcome?.result, .cancelled)
        XCTAssertLessThanOrEqual(coordinator.lastOutcome!.summary.batchesDelivered, 1)
        XCTAssertNil(coordinator.lastSuccessfulSync)
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
        metrics: Set<HealthMetric>
    ) async throws -> HealthExportResult {
        exportedMetrics.append(contentsOf: metrics.sorted { $0.rawValue < $1.rawValue })
        return HealthExportResult(
            records: exportRecords.filter { metrics.contains($0.metric) },
            truncatedMetrics: truncated
        )
    }
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
        ReceiverHealthResponse(status: "ok", service: "vitalroute-receiver", apiVersion: 1)
    }
}

/// A one-shot gate that lets tests pause an async operation at a known point.
private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var opened = false

    func enter() async {
        lock.lock()
        entered = true
        while !opened {
            lock.unlock()
            try? await Task.sleep(nanoseconds: 2_000_000)
            lock.lock()
        }
        lock.unlock()
    }

    func waitForEntry() async {
        while !isEntered {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    var isEntered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }

    func open() {
        lock.lock()
        opened = true
        lock.unlock()
    }
}
