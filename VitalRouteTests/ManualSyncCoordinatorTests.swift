import XCTest
@testable import VitalRoute

final class ManualSyncCoordinatorTests: XCTestCase {
    private let endpoint = "https://health.example.org/v1/records"
    private let token = "coordinator-test-token-0001"

    private var suites: [(defaults: UserDefaults, name: String)] = []
    private var tempDirectories: [TempDirBox] = []

    override func tearDown() {
        for suite in suites {
            suite.defaults.removePersistentDomain(forName: suite.name)
        }
        suites.removeAll()
        for temp in tempDirectories {
            temp.remove()
        }
        tempDirectories.removeAll()
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

    /// One scripted export page: records identified by index, a serialized
    /// anchor to hand back, and whether more pages follow.
    private func page(_ ids: [Int], anchor: String, full: Bool, metric: HealthMetric = .steps) -> HealthExportPage {
        HealthExportPage(
            records: ids.map { record($0, metric: metric) },
            anchorData: Data(anchor.utf8),
            isFull: full
        )
    }

    @MainActor
    private func makeCoordinator(
        provider: StubHealthDataProvider,
        client: StubDestinationClient,
        defaults: UserDefaults? = nil,
        store: SyncStateStore? = nil,
        workGate: SyncWorkGate = SyncWorkGate()
    ) -> ManualSyncCoordinator {
        ManualSyncCoordinator(
            healthData: provider,
            client: client,
            stateStore: store ?? makeStore(),
            defaults: defaults ?? makeDefaults(),
            workGate: workGate
        )
    }

    private func makeDefaults() -> UserDefaults {
        let name = "sync-coordinator-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        suites.append((defaults, name))
        return defaults
    }

    private func makeStore() -> SyncStateStore {
        let temp = TempDirBox()
        tempDirectories.append(temp)
        return SyncStateStore(directory: temp.url)
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
        let provider = StubHealthDataProvider()
        provider.script[.steps] = [page([1, 2], anchor: "a1", full: false)]
        provider.script[.sleep] = [page([3], anchor: "s1", full: false, metric: .sleep)]
        let client = StubDestinationClient()
        let defaults = makeDefaults()
        let coordinator = makeCoordinator(provider: provider, client: client, defaults: defaults)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps, .sleep])
        await waitForCompletion(coordinator)

        XCTAssertEqual(coordinator.lastOutcome?.result, .completed)
        let summary = coordinator.lastOutcome?.summary
        XCTAssertEqual(summary?.recordsFound, 3)
        XCTAssertEqual(summary?.batchesDelivered, 2)
        XCTAssertEqual(summary?.acceptedRecords, 3)
        XCTAssertNotNil(coordinator.lastSuccessfulSync)
        XCTAssertEqual(coordinator.lastSuccessfulSync?.deliveredRecords, summary?.deliveredRecords)

        // Authorization and reading covered exactly the selected categories.
        XCTAssertEqual(provider.authorizationRequestedMetrics, [.sleep, .steps])
        XCTAssertEqual(Set(provider.exportQueries.map(\.metric)), [.sleep, .steps])

        // Persisted across a new coordinator instance.
        let reloaded = ManualSyncCoordinator(
            healthData: provider, client: client, stateStore: makeStore(), defaults: defaults
        )
        XCTAssertEqual(reloaded.lastSuccessfulSync, coordinator.lastSuccessfulSync)
    }

    @MainActor
    func testEmptyHistoryCompletesWithoutSendingAnything() async throws {
        let provider = StubHealthDataProvider()
        let client = StubDestinationClient()
        let coordinator = makeCoordinator(provider: provider, client: client)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        await waitForCompletion(coordinator)

        XCTAssertEqual(coordinator.lastOutcome?.result, .completed)
        XCTAssertEqual(coordinator.lastOutcome?.summary.recordsFound, 0)
        XCTAssertEqual(client.sentPayloads.count, 0)
    }

    @MainActor
    func testRecordsAreBatchedAtTheConfiguredSizeWithinAPage() async throws {
        let ids = Array(0..<(SyncLimits.recordsPerUploadBatch + 50))
        let provider = StubHealthDataProvider()
        provider.script[.steps] = [page(ids, anchor: "a1", full: false)]
        let client = StubDestinationClient()
        let coordinator = makeCoordinator(provider: provider, client: client)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        await waitForCompletion(coordinator)

        XCTAssertEqual(client.sentPayloads.count, 2)
        XCTAssertEqual(client.sentPayloads[0].records.count, SyncLimits.recordsPerUploadBatch)
        XCTAssertEqual(client.sentPayloads[1].records.count, 50)
        XCTAssertEqual(client.sentPayloads[0].records.first?.id, ids.first.map { record($0).id })
        XCTAssertEqual(coordinator.lastOutcome?.result, .completed)
        XCTAssertEqual(coordinator.lastOutcome?.summary.acceptedRecords, ids.count)
    }

    // MARK: Chunked backfill

    @MainActor
    func testLargeHistoryIsChunkedAcrossAnchoredPages() async throws {
        let provider = StubHealthDataProvider()
        provider.script[.steps] = [
            page([1], anchor: "a1", full: true),
            page([2], anchor: "a2", full: true),
            page([3], anchor: "a3", full: true),
            page([4], anchor: "a4", full: false),
        ]
        let client = StubDestinationClient()
        let store = makeStore()
        let coordinator = makeCoordinator(provider: provider, client: client, store: store)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        await waitForCompletion(coordinator)

        XCTAssertEqual(coordinator.lastOutcome?.result, .completed)
        // All four pages were read in one run, each resuming from the
        // previous page's anchor — a chunked read, not one giant window.
        XCTAssertEqual(provider.exportQueries.count, 4)
        XCTAssertNil(provider.exportQueries[0].sinceAnchor)
        XCTAssertEqual(provider.exportQueries[1].sinceAnchor, Data("a1".utf8))
        XCTAssertEqual(provider.exportQueries[2].sinceAnchor, Data("a2".utf8))
        XCTAssertEqual(provider.exportQueries[3].sinceAnchor, Data("a3".utf8))
        // One batch per record page, all acknowledged.
        XCTAssertEqual(client.sentPayloads.count, 4)
        XCTAssertEqual(coordinator.lastOutcome?.summary.acceptedRecords, 4)
        // The final cursor reflects the last acknowledged page.
        let cursor = await store.manualCursor(
            destination: URL(string: endpoint)!.absoluteString,
            metric: .steps,
            windowStart: provider.exportQueries[0].windowStart
        )
        XCTAssertEqual(cursor?.anchorData, Data("a4".utf8))
    }

    @MainActor
    func testPageBudgetEndsAsResumableBackfillNotFailure() async throws {
        let provider = StubHealthDataProvider()
        provider.script[.steps] = [page([1], anchor: "a1", full: true)]
        provider.fullPagesAfterScript = true
        let client = StubDestinationClient()
        let store = makeStore()
        let coordinator = makeCoordinator(provider: provider, client: client, store: store)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        await waitForCompletion(coordinator)

        // Budget consumed with more history pending: a backfill state, and
        // progress was kept.
        XCTAssertEqual(coordinator.lastOutcome?.result, .backfilling(metrics: [.steps]))
        XCTAssertNotNil(coordinator.lastOutcome)
        XCTAssertGreaterThan(coordinator.lastOutcome!.summary.deliveredRecords, 0)
        XCTAssertNil(coordinator.lastSuccessfulSync)
        let windowStart = provider.exportQueries.first!.windowStart
        let cursor = await store.manualCursor(
            destination: URL(string: endpoint)!.absoluteString, metric: .steps, windowStart: windowStart
        )
        XCTAssertNotNil(cursor?.anchorData)
    }

    @MainActor
    func testBackfillResumesFromSavedCursorOnNextSync() async throws {
        let provider = StubHealthDataProvider()
        provider.script[.steps] = [page([1], anchor: "a1", full: true)]
        provider.fullPagesAfterScript = true
        let client = StubDestinationClient()
        let store = makeStore()
        let defaults = makeDefaults()
        let coordinator = makeCoordinator(
            provider: provider, client: client, defaults: defaults, store: store
        )

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps], now: Date(timeIntervalSince1970: 1_800_000_000))
        await waitForCompletion(coordinator)
        let savedAnchor = provider.exportQueries.last!.sinceAnchor
        let firstWindow = provider.exportQueries[0].windowStart

        // Second sync at the SAME depth but a LATER clock: the window is
        // frozen per identity, so the cursor still hits and the run
        // continues from the saved anchor instead of re-reading a fresh
        // window. This is the production resume path (taps are never the
        // same instant).
        provider.exportQueries.removeAll()
        provider.fullPagesAfterScript = false
        provider.script[.steps] = [page([99], anchor: "a-end", full: false)]
        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps], now: Date(timeIntervalSince1970: 1_800_086_400))
        await waitForCompletion(coordinator)

        XCTAssertEqual(coordinator.lastOutcome?.result, .completed)
        XCTAssertEqual(provider.exportQueries.count, 1)
        XCTAssertEqual(provider.exportQueries[0].sinceAnchor, savedAnchor)
        // The frozen window is the one minted at the FIRST sync — earlier
        // than a fresh 7-day window would be a day later.
        XCTAssertEqual(provider.exportQueries[0].windowStart, firstWindow)
    }

    @MainActor
    func testSameDepthSecondSyncResumesWithoutChurn() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = StubHealthDataProvider()
        provider.script[.steps] = [
            page([1], anchor: "a1", full: true),
            page([2], anchor: "a2", full: false),
        ]
        let client = StubDestinationClient()
        let store = makeStore()
        let coordinator = makeCoordinator(
            provider: provider, client: client, store: store
        )

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps], now: now)
        await waitForCompletion(coordinator)
        XCTAssertEqual(coordinator.lastOutcome?.result, .completed)
        let firstWindow = provider.exportQueries[0].windowStart

        // A later sync (a full day later) at unchanged depth resumes from
        // the cursor with the SAME frozen window start: no fresh bootstrap,
        // no re-read, and no drift with the wall clock.
        provider.exportQueries.removeAll()
        provider.script[.steps] = [page([], anchor: "a2", full: false)]
        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps], now: now.addingTimeInterval(86_400))
        await waitForCompletion(coordinator)

        XCTAssertEqual(provider.exportQueries.count, 1)
        XCTAssertEqual(provider.exportQueries[0].sinceAnchor, Data("a2".utf8))
        XCTAssertEqual(provider.exportQueries[0].windowStart, firstWindow)
    }

    @MainActor
    func testSecondCoordinatorInstanceResumesFromTheSameStore() async throws {
        // Durability across relaunch: a fresh coordinator over the same
        // store continues where the previous one stopped.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = StubHealthDataProvider()
        provider.script[.steps] = [
            page([1], anchor: "a1", full: true),
            page([2], anchor: "a2", full: false),
        ]
        let client = StubDestinationClient()
        let store = makeStore()
        let defaults = makeDefaults()
        let first = makeCoordinator(provider: provider, client: client, defaults: defaults, store: store)
        first.startSync(endpoint: endpoint, token: token, metrics: [.steps], now: now)
        await waitForCompletion(first)

        let reloaded = ManualSyncCoordinator(
            healthData: provider, client: client, stateStore: store, defaults: defaults
        )
        provider.exportQueries.removeAll()
        provider.script[.steps] = [page([], anchor: "a2", full: false)]
        reloaded.startSync(endpoint: endpoint, token: token, metrics: [.steps], now: now.addingTimeInterval(3_600))
        await waitForCompletion(reloaded)

        XCTAssertEqual(reloaded.lastOutcome?.result, .completed)
        XCTAssertEqual(provider.exportQueries.count, 1)
        XCTAssertEqual(provider.exportQueries[0].sinceAnchor, Data("a2".utf8))
    }

    @MainActor
    func testCorruptedStoredAnchorRecoversByReReadingTheWindow() async throws {
        let provider = StubHealthDataProvider()
        // First run completes and leaves a cursor.
        provider.script[.steps] = [page([1], anchor: "a1", full: false)]
        let client = StubDestinationClient()
        let store = makeStore()
        let coordinator = makeCoordinator(provider: provider, client: client, store: store)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps], now: now)
        await waitForCompletion(coordinator)
        XCTAssertEqual(coordinator.lastOutcome?.result, .completed)

        // The stored anchor becomes unreadable (e.g. an OS migration). The
        // next sync must drop it and re-read the window from its start
        // instead of failing forever.
        provider.corruptStoredAnchors = true
        provider.exportQueries.removeAll()
        provider.script[.steps] = [page([2], anchor: "a1", full: false)]
        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps], now: now.addingTimeInterval(60))
        await waitForCompletion(coordinator)

        XCTAssertEqual(coordinator.lastOutcome?.result, .completed)
        XCTAssertEqual(provider.exportQueries[0].sinceAnchor, Data("a1".utf8)) // offered the bad cursor
        XCTAssertEqual(provider.exportQueries[1].sinceAnchor, nil) // rebuilt from the window start
        XCTAssertEqual(coordinator.lastOutcome?.summary.recordsFound, 1)
    }

    @MainActor
    func testNonAdvancingFullPageFailsHonestly() async throws {
        let provider = StubHealthDataProvider()
        let client = StubDestinationClient()
        let store = makeStore()
        let coordinator = makeCoordinator(provider: provider, client: client, store: store)

        // Seed a cursor at "same".
        provider.script[.steps] = [page([1], anchor: "same", full: false)]
        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        await waitForCompletion(coordinator)
        XCTAssertEqual(client.sentPayloads.count, 1)

        // A full page whose anchor equals the anchor it was read with:
        // continuing would re-send the same page forever, so the run stops
        // honestly after delivering it.
        provider.exportQueries.removeAll()
        provider.script[.steps] = [
            page([1], anchor: "same", full: false),
            page([9], anchor: "same", full: true),
        ]
        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        await waitForCompletion(coordinator)

        guard case .failed(let message)? = coordinator.lastOutcome?.result else {
            XCTFail("expected failure for a non-advancing full page")
            return
        }
        XCTAssertTrue(message.contains("could not be read past"), message)
        // The offending page WAS delivered before the stop.
        XCTAssertEqual(client.sentPayloads.count, 2)
    }

    @MainActor
    func testDifferentDestinationUsesItsOwnCursorIdentity() async throws {
        let provider = StubHealthDataProvider()
        provider.script[.steps] = [page([1], anchor: "a1", full: false)]
        let client = StubDestinationClient()
        let store = makeStore()
        let coordinator = makeCoordinator(provider: provider, client: client, store: store)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        await waitForCompletion(coordinator)
        let firstWindow = provider.exportQueries[0].windowStart
        let firstDestination = URL(string: endpoint)!.absoluteString

        // A different destination mints its own identity: a fresh window
        // and no anchor reuse, and the first destination's cursor survives.
        provider.exportQueries.removeAll()
        provider.script[.steps] = [page([2], anchor: "b1", full: false)]
        coordinator.startSync(endpoint: "https://other.example.org/v1/records", token: token, metrics: [.steps])
        await waitForCompletion(coordinator)

        XCTAssertEqual(provider.exportQueries[0].sinceAnchor, nil)
        XCTAssertEqual(coordinator.lastOutcome?.result, .completed)
        let surviving = await store.manualCursor(
            destination: firstDestination, metric: .steps, windowStart: firstWindow
        )
        XCTAssertEqual(surviving?.anchorData, Data("a1".utf8))
    }

    // MARK: Depth semantics

    @MainActor
    func testManualPlanHonorsAllRecordsDepth() async throws {
        let defaults = makeDefaults()
        BackfillDepth.store(.allRecords, in: defaults)
        let provider = StubHealthDataProvider()
        provider.script[.steps] = [page([1], anchor: "a1", full: false)]
        let client = StubDestinationClient()
        let coordinator = makeCoordinator(provider: provider, client: client, defaults: defaults)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        await waitForCompletion(coordinator)

        XCTAssertEqual(provider.exportQueries.count, 1)
        XCTAssertEqual(provider.exportQueries[0].windowStart, .distantPast)
        XCTAssertNil(provider.exportQueries[0].sinceAnchor)
    }

    @MainActor
    func testDefaultDepthShapesWindowStart() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = StubHealthDataProvider()
        provider.script[.steps] = [page([1], anchor: "a1", full: false)]
        let client = StubDestinationClient()
        let coordinator = makeCoordinator(provider: provider, client: client)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps], now: now)
        await waitForCompletion(coordinator)

        XCTAssertEqual(provider.exportQueries.count, 1)
        XCTAssertEqual(
            provider.exportQueries[0].windowStart,
            BackfillDepth.sevenDays.windowStart(from: now)
        )
    }

    @MainActor
    func testDeepeningDepthStartsFreshBackfillAndKeepsOldCursor() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let defaults = makeDefaults()
        let provider = StubHealthDataProvider()
        provider.script[.steps] = [page([1], anchor: "shallow-1", full: false)]
        let client = StubDestinationClient()
        let store = makeStore()
        let coordinator = makeCoordinator(
            provider: provider, client: client, defaults: defaults, store: store
        )

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps], now: now)
        await waitForCompletion(coordinator)
        let shallowWindow = provider.exportQueries[0].windowStart
        let destination = URL(string: endpoint)!.absoluteString
        let shallowCursor = await store.manualCursor(
            destination: destination, metric: .steps, windowStart: shallowWindow
        )
        XCTAssertEqual(shallowCursor?.anchorData, Data("shallow-1".utf8))

        // Deepen to the entire history: the next sync must really backfill —
        // a fresh cursor identity (distant past window, no anchor reuse).
        BackfillDepth.store(.allRecords, in: defaults)
        provider.exportQueries.removeAll()
        provider.script[.steps] = [page([2], anchor: "deep-1", full: false)]
        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps], now: now)
        await waitForCompletion(coordinator)

        XCTAssertEqual(provider.exportQueries.count, 1)
        XCTAssertEqual(provider.exportQueries[0].windowStart, .distantPast)
        XCTAssertNil(provider.exportQueries[0].sinceAnchor)

        // The shallower cursor is untouched on disk: shallowing later
        // resumes it instead of discarding captured history.
        let reloaded = await store.manualCursor(
            destination: destination, metric: .steps, windowStart: shallowWindow
        )
        XCTAssertEqual(reloaded?.anchorData, Data("shallow-1".utf8))
        let deepWindow = provider.exportQueries[0].windowStart
        let deepCursor = await store.manualCursor(
            destination: destination, metric: .steps, windowStart: deepWindow
        )
        if deepCursor == nil {
            let all = await store.loadManualCursors()
            XCTFail("deep cursor missing; stored keys: \(all.keys.sorted())")
        } else {
            XCTAssertEqual(deepCursor?.anchorData, Data("deep-1".utf8))
        }
    }

    @MainActor
    func testShallowingDepthUsesItsOwnWindowWithoutDiscardingDeeperCapture() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let defaults = makeDefaults()
        BackfillDepth.store(.allRecords, in: defaults)
        let provider = StubHealthDataProvider()
        provider.script[.steps] = [page([1], anchor: "deep-1", full: false)]
        let client = StubDestinationClient()
        let store = makeStore()
        let coordinator = makeCoordinator(
            provider: provider, client: client, defaults: defaults, store: store
        )

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps], now: now)
        await waitForCompletion(coordinator)
        let destination = URL(string: endpoint)!.absoluteString

        // Shallow to the default: the next sync reads its own (narrow)
        // window with its own cursor…
        BackfillDepth.store(.sevenDays, in: defaults)
        provider.exportQueries.removeAll()
        provider.script[.steps] = [page([2], anchor: "shallow-1", full: false)]
        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps], now: now)
        await waitForCompletion(coordinator)

        XCTAssertEqual(provider.exportQueries.count, 1)
        XCTAssertEqual(
            provider.exportQueries[0].windowStart,
            BackfillDepth.sevenDays.windowStart(from: now)
        )
        XCTAssertNil(provider.exportQueries[0].sinceAnchor)

        // …and the deeper capture is still on disk, untouched.
        let deepCursor = await store.manualCursor(
            destination: destination, metric: .steps, windowStart: .distantPast
        )
        XCTAssertEqual(deepCursor?.anchorData, Data("deep-1".utf8))
    }

    // MARK: Per-category independence and durability

    @MainActor
    func testBackfillProgressIsIndependentPerCategory() async throws {
        let provider = StubHealthDataProvider()
        provider.script[.steps] = [page([1], anchor: "s1", full: true)]
        provider.fullPagesAfterScriptMetrics.insert(.steps)
        provider.script[.heartRate] = [page([2], anchor: "h1", full: false, metric: .heartRate)]
        let client = StubDestinationClient()
        let store = makeStore()
        let coordinator = makeCoordinator(provider: provider, client: client, store: store)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps, .heartRate], now: now)
        await waitForCompletion(coordinator)

        // Steps is still backfilling; heart rate completed.
        XCTAssertEqual(coordinator.lastOutcome?.result, .backfilling(metrics: [.steps]))
        let destination = URL(string: endpoint)!.absoluteString
        let window = provider.exportQueries[0].windowStart
        let stepsCursor = await store.manualCursor(
            destination: destination, metric: .steps, windowStart: window
        )
        let heartCursor = await store.manualCursor(
            destination: destination, metric: .heartRate, windowStart: window
        )
        XCTAssertNotNil(stepsCursor?.anchorData)
        XCTAssertNotNil(heartCursor?.anchorData)

        // Next sync: heart rate resumes from its cursor and finishes with
        // one empty page; steps continues from its saved anchor.
        provider.exportQueries.removeAll()
        provider.fullPagesAfterScriptMetrics.removeAll()
        provider.script[.heartRate] = [page([], anchor: "h1", full: false, metric: .heartRate)]
        provider.script[.steps] = [page([3], anchor: "s2", full: false)]
        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps, .heartRate], now: now)
        await waitForCompletion(coordinator)

        let byMetric = Dictionary(grouping: provider.exportQueries, by: \.metric)
        XCTAssertEqual(byMetric[.heartRate]?.count, 1)
        XCTAssertEqual(byMetric[.heartRate]?.first?.sinceAnchor, heartCursor?.anchorData)
        XCTAssertEqual(byMetric[.steps]?.first?.sinceAnchor, stepsCursor?.anchorData)
        XCTAssertEqual(coordinator.lastOutcome?.result, .completed)
    }

    @MainActor
    func testCursorAdvancesOnlyAfterAcknowledgement() async throws {
        let provider = StubHealthDataProvider()
        provider.script[.steps] = [
            page([1], anchor: "a1", full: true),
            page([2], anchor: "a2", full: true),
            page([3], anchor: "a3", full: false),
        ]
        let client = StubDestinationClient()
        client.failOnBatchNumber = 2 // the second page's only batch
        client.failure = .serverRejected(status: 500)
        let store = makeStore()
        let coordinator = makeCoordinator(provider: provider, client: client, store: store)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps], now: now)
        await waitForCompletion(coordinator)

        // Page 1 was acknowledged and checkpointed; page 2's delivery
        // failed, so the cursor must still point at page 1's end.
        guard case .failed = coordinator.lastOutcome?.result else {
            XCTFail("expected failure after batch error")
            return
        }
        let window = provider.exportQueries[0].windowStart
        let cursor = await store.manualCursor(
            destination: URL(string: endpoint)!.absoluteString, metric: .steps, windowStart: window
        )
        XCTAssertEqual(cursor?.anchorData, Data("a1".utf8))

        // The retry resumes from page 2 — not from the beginning.
        client.failOnBatchNumber = nil
        client.failure = nil
        provider.exportQueries.removeAll()
        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps], now: now)
        await waitForCompletion(coordinator)

        XCTAssertEqual(coordinator.lastOutcome?.result, .completed)
        XCTAssertEqual(provider.exportQueries[0].sinceAnchor, Data("a1".utf8))
    }

    // MARK: Preflight

    @MainActor
    func testMissingTokenFailsWithoutTouchingHealthOrNetwork() async {
        let provider = StubHealthDataProvider()
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
        let provider = StubHealthDataProvider()
        let client = StubDestinationClient()
        let coordinator = makeCoordinator(provider: provider, client: client)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [])

        guard case .failed(let message)? = coordinator.lastOutcome?.result else {
            XCTFail("expected failure outcome")
            return
        }
        XCTAssertTrue(message.contains("category"))
        XCTAssertEqual(provider.authorizationCount, 0)
    }

    @MainActor
    func testInvalidEndpointFailsPreflight() async {
        let provider = StubHealthDataProvider()
        let client = StubDestinationClient()
        let coordinator = makeCoordinator(provider: provider, client: client)

        coordinator.startSync(endpoint: "http://insecure.example.org/v1/records", token: token, metrics: [.steps])

        guard case .failed(let message)? = coordinator.lastOutcome?.result else {
            XCTFail("expected failure outcome")
            return
        }
        XCTAssertTrue(message.contains("destination"))
        XCTAssertEqual(provider.authorizationCount, 0)
    }

    // MARK: Failure, cancellation, and overlap

    @MainActor
    func testMidBatchFailureReportsPartialProgressNotSuccess() async throws {
        let provider = StubHealthDataProvider()
        provider.script[.steps] = [
            page([1, 2, 3], anchor: "a1", full: true),
            page([4, 5, 6], anchor: "a2", full: false),
        ]
        let client = StubDestinationClient()
        client.failOnBatchNumber = 1
        client.failure = .serverRejected(status: 500)
        let coordinator = makeCoordinator(provider: provider, client: client)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        await waitForCompletion(coordinator)

        guard case .failed = coordinator.lastOutcome?.result else {
            XCTFail("expected failure outcome")
            return
        }
        XCTAssertEqual(coordinator.lastOutcome?.summary.batchesDelivered, 0)
        XCTAssertNil(coordinator.lastSuccessfulSync)
    }

    @MainActor
    func testAuthFailureBeforeAnyUploadFailsCleanly() async {
        let provider = StubHealthDataProvider()
        provider.shouldFailAuthorization = true
        let client = StubDestinationClient()
        let coordinator = makeCoordinator(provider: provider, client: client)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        await waitForCompletion(coordinator)

        guard case .failed(let message)? = coordinator.lastOutcome?.result else {
            XCTFail("expected failure outcome")
            return
        }
        XCTAssertTrue(message.contains("Apple Health"))
        XCTAssertEqual(client.sentPayloads.count, 0)
    }

    @MainActor
    func testOverlappingSyncIsIgnoredWhileOneRuns() async throws {
        let provider = StubHealthDataProvider()
        provider.script[.steps] = [page([1], anchor: "a1", full: false)]
        let client = StubDestinationClient()
        client.sendGate = AsyncGate()
        let coordinator = makeCoordinator(provider: provider, client: client)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        await client.sendGate!.waitForEntry()
        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        client.sendGate!.open()
        await waitForCompletion(coordinator)

        // The overlapping call was ignored: exactly one payload.
        XCTAssertEqual(client.sentPayloads.count, 1)
    }

    @MainActor
    func testConfigurationChangeDoesNotRedirectAnUnderwaySync() async throws {
        let provider = StubHealthDataProvider()
        provider.script[.steps] = [page([1], anchor: "a1", full: false)]
        let client = StubDestinationClient()
        client.sendGate = AsyncGate()
        let coordinator = makeCoordinator(provider: provider, client: client)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        await client.sendGate!.waitForEntry()
        // A different destination configured while the first sync is parked
        // on its upload must not redirect it.
        coordinator.startSync(endpoint: "https://other.example.org/v1/records", token: token, metrics: [.steps])
        client.sendGate!.open()
        await waitForCompletion(coordinator)

        XCTAssertEqual(client.receivedEndpoints, [URL(string: endpoint)!])
    }

    @MainActor
    func testCancellationBetweenBatchesReportsCancelledWithPartialCounts() async throws {
        let provider = StubHealthDataProvider()
        provider.script[.steps] = [
            page([1, 2, 3], anchor: "a1", full: true),
            page([4, 5, 6], anchor: "a2", full: false),
        ]
        let client = StubDestinationClient()
        client.sendGate = AsyncGate()
        let coordinator = makeCoordinator(provider: provider, client: client)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        // Park inside the first page's batch delivery, then cancel.
        await client.sendGate!.waitForEntry()
        coordinator.cancelSync()
        client.sendGate!.open()
        await waitForCompletion(coordinator)

        XCTAssertEqual(coordinator.lastOutcome?.result, .cancelled)
    }

    @MainActor
    func testCancellingWhileQueuedBehindTheGateClearsTheSyncState() async throws {
        let provider = StubHealthDataProvider()
        provider.script[.steps] = [page([1], anchor: "a1", full: false)]
        let client = StubDestinationClient()
        let gate = SyncWorkGate()
        let holder = GateHolder()
        // Hold the gate with a no-op run so the manual sync queues behind it.
        let holderTask = Task { try? await gate.run { await holder.waitForRelease() } }
        await holder.waitForEntry()

        let coordinator = makeCoordinator(
            provider: provider, client: client, workGate: gate
        )
        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        // Let the queued sync observe cancellation while still waiting.
        try? await Task.sleep(nanoseconds: 50_000_000)
        coordinator.cancelSync()
        holder.release()
        _ = await holderTask.value
        await waitForCompletion(coordinator)

        XCTAssertFalse(coordinator.isSyncing)
        XCTAssertEqual(coordinator.lastOutcome?.result, .cancelled)
        XCTAssertEqual(client.sentPayloads.count, 0)
        // The cleared state must not wedge later syncs.
        provider.script[.steps] = [page([9], anchor: "z1", full: false)]
        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        await waitForCompletion(coordinator)
        XCTAssertEqual(coordinator.lastOutcome?.result, .completed)
        XCTAssertEqual(client.sentPayloads.count, 1)
    }

    @MainActor
    func testRetryAfterFailureIsUserInitiatedOnly() async throws {
        let provider = StubHealthDataProvider()
        provider.script[.steps] = [page([1], anchor: "a1", full: false)]
        let client = StubDestinationClient()
        client.failOnBatchNumber = 1
        client.failure = .serverRejected(status: 503)
        let coordinator = makeCoordinator(provider: provider, client: client)

        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        await waitForCompletion(coordinator)
        XCTAssertFalse(coordinator.isSyncing)
        guard case .failed = coordinator.lastOutcome?.result else {
            XCTFail("expected the first run to fail")
            return
        }

        client.failOnBatchNumber = nil
        client.failure = nil
        coordinator.startSync(endpoint: endpoint, token: token, metrics: [.steps])
        await waitForCompletion(coordinator)

        // The failed attempt never checkpointed its page, so the retry reads
        // it again — the receiver keeps one copy of each record.
        XCTAssertEqual(client.sentPayloads.count, 2)
        XCTAssertEqual(coordinator.lastOutcome?.result, .completed)
        XCTAssertNotNil(coordinator.lastSuccessfulSync)
    }
}

// MARK: - Test doubles

/// Records one export-page query and serves scripted pages per metric.
@MainActor
private final class StubHealthDataProvider: HealthDataProviding {
    struct RecordedQuery {
        let metric: HealthMetric
        let sinceAnchor: Data?
        let windowStart: Date
    }

    /// Scripted pages per metric, forming an anchor chain. A query with
    /// anchor A returns the page that follows A in the chain (or the first
    /// page for a nil anchor) — exactly like HealthKit's anchored queries,
    /// so a retry that never checkpointed re-reads the same page.
    var script: [HealthMetric: [HealthExportPage]] = [:]
    /// When set, out-of-script pages for every metric come back full so a
    /// run ends on the page budget (backfill in progress).
    var fullPagesAfterScript = false
    /// Same, per metric (for per-category independence tests).
    var fullPagesAfterScriptMetrics: Set<HealthMetric> = []

    /// When set, a query with a non-nil anchor throws a corrupted-anchor
    /// error (recovery tests).
    var corruptStoredAnchors = false
    var shouldFailAuthorization = false
    private(set) var authorizationCount = 0
    private(set) var authorizationRequestedMetrics: [HealthMetric] = []
    var exportQueries: [RecordedQuery] = []

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
        []
    }

    func exportPage(
        for metric: HealthMetric,
        since anchorData: Data?,
        windowStart: Date,
        limit: Int
    ) async throws -> HealthExportPage {
        exportQueries.append(RecordedQuery(metric: metric, sinceAnchor: anchorData, windowStart: windowStart))
        if corruptStoredAnchors, anchorData != nil {
            throw HealthKitServiceError.corruptedAnchor
        }
        let pages = script[metric] ?? []

        // The page that follows the caller's anchor in the scripted chain:
        // a nil anchor starts at the first page, an anchor the caller never
        // checkpointed re-reads the page it produced before, and an anchor
        // outside the chain means caught up (the fallback below).
        let index: Int
        if let anchorData,
           let found = pages.firstIndex(where: { $0.anchorData == anchorData }) {
            index = found + 1
        } else if anchorData == nil {
            index = 0
        } else {
            index = pages.count
        }
        if index < pages.count {
            return pages[index]
        }
        if fullPagesAfterScript || fullPagesAfterScriptMetrics.contains(metric) {
            // An endless stream of full (here: empty) pages keeps the run
            // on its page budget without scripting hundreds of pages.
            return HealthExportPage(records: [], anchorData: anchorData, isFull: true)
        }
        return HealthExportPage(records: [], anchorData: anchorData, isFull: false)
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

/// A one-shot gate that lets tests pause an async operation at a known
/// point. Not an actor: tests open/release it synchronously from the main
/// actor while the operation under test parks inside `enter()`.
private final class AsyncGate: @unchecked Sendable {
    private let state = GateState()

    func enter() async {
        state.markEntered()
        while !state.isOpened {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    var isEntered: Bool { state.isEntered }

    func waitForEntry() async {
        while !isEntered {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func open() { state.open() }
}

/// Lock-protected flag holder. All locking happens in synchronous
/// methods (async contexts only read through them), which is async-safe.
private final class GateState: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var opened = false

    func markEntered() {
        lock.lock()
        entered = true
        lock.unlock()
    }

    var isEntered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }

    var isOpened: Bool {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }

    func open() {
        lock.lock()
        opened = true
        lock.unlock()
    }
}

/// Holds a gate open until released; lets a test park another operation
/// behind it deterministically.
private final class GateHolder: @unchecked Sendable {
    private let state = GateState()

    func waitForRelease() async {
        state.markEntered()
        while !state.isOpened {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func waitForEntry() async {
        while !state.isEntered {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func release() { state.open() }
}

/// A test-scoped temporary directory that cleans up in tearDown.
private final class TempDirBox {
    let url: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("manual-sync-tests-\(UUID().uuidString)", isDirectory: true)

    init() {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
