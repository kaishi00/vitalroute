import XCTest
@testable import VitalRoute

/// Real file-backed stores in isolated temp directories, so durability and
/// crash-window behavior are exercised against actual atomic writes.
final class OutboxAndStateStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vitalroute-outbox-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func makeOutbox() -> Outbox {
        Outbox(directory: tempDirectory)
    }

    private func makeStateStore() -> SyncStateStore {
        SyncStateStore(directory: tempDirectory)
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

    private func deletion(_ id: Int, metric: HealthMetric = .steps) -> SyncChangeEvent {
        .delete(DeletedRecord(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            metric: metric,
            startDate: Date(timeIntervalSince1970: 1_735_689_600),
            endDate: Date(timeIntervalSince1970: 1_735_689_660)
        ))
    }

    func testAppendDeduplicatesAndPreservesInsertionOrder() async throws {
        let outbox = makeOutbox()
        try await outbox.prepare()

        _ = try await outbox.append([.upsert(record(1)), .upsert(record(2))], lane: .backfill)
        // Crash-replay of the same events must not duplicate.
        _ = try await outbox.append([.upsert(record(2)), .upsert(record(3))], lane: .backfill)

        let snapshot = try await outbox.nextBatch()
        XCTAssertEqual(snapshot.totalPending, 3)
        XCTAssertEqual(snapshot.events.map(\.eventID), [
            SyncChangeEvent.upsert(record(1)).eventID,
            SyncChangeEvent.upsert(record(2)).eventID,
            SyncChangeEvent.upsert(record(3)).eventID,
        ])
    }

    func testNextBatchPagesAndRemoveClearsAcknowledged() async throws {
        let outbox = makeOutbox()
        try await outbox.prepare()
        let events = (1...250).map { SyncChangeEvent.upsert(record($0)) }
        _ = try await outbox.append(events, lane: .backfill)

        let first = try await outbox.nextBatch()
        XCTAssertEqual(first.events.count, Outbox.deliveryBatchSize)
        XCTAssertEqual(first.totalPending, 250)

        await outbox.remove(eventIDs: first.events.map(\.eventID))
        let second = try await outbox.nextBatch()
        XCTAssertEqual(second.totalPending, 50)
        XCTAssertEqual(second.events.count, 50)
    }

    func testRemoveOnlyAfterAcknowledgedKeepsOthers() async throws {
        let outbox = makeOutbox()
        try await outbox.prepare()
        _ = try await outbox.append([.upsert(record(1)), deletion(2), .upsert(record(3))], lane: .backfill)

        // Simulate: only record 1's batch was acknowledged.
        await outbox.remove(eventIDs: [SyncChangeEvent.upsert(record(1)).eventID])
        let snapshot = try await outbox.nextBatch()
        XCTAssertEqual(snapshot.totalPending, 2)
        XCTAssertEqual(snapshot.events.first, deletion(2))
    }

    func testRemoveCategoryDropsOnlyThatCategory() async throws {
        let outbox = makeOutbox()
        try await outbox.prepare()
        _ = try await outbox.append([
            .upsert(record(1, metric: .steps)),
            .upsert(record(2, metric: .sleep)),
            deletion(3, metric: .sleep),
        ], lane: .backfill)

        await outbox.removeCategory(.sleep)

        let snapshot = try await outbox.nextBatch()
        XCTAssertEqual(snapshot.totalPending, 1)
        XCTAssertEqual(snapshot.events.first?.metric, .steps)
    }

    func testCapacityBackpressureFlag() async throws {
        let outbox = makeOutbox()
        try await outbox.prepare()
        var events: [SyncChangeEvent] = []
        for index in 0..<Outbox.capacityLimit {
            events.append(.upsert(record(index + 1)))
        }
        _ = try await outbox.append(events, lane: .backfill)

        let atCapacity = try await outbox.isAtCapacity()
        XCTAssertTrue(atCapacity)

        // Drain one batch; below capacity again.
        let batch = try await outbox.nextBatch()
        await outbox.remove(eventIDs: batch.events.map(\.eventID))
        let drained = try await outbox.isAtCapacity()
        XCTAssertFalse(drained)
    }

    func testCorruptEventFileIsQuarantinedNotStalling() async throws {
        let outbox = makeOutbox()
        try await outbox.prepare()
        _ = try await outbox.append([.upsert(record(1)), .upsert(record(2))], lane: .backfill)

        // Corrupt the first event file in insertion order.
        let files = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.appendingPathComponent("outbox").path)
        let sorted = files.filter { $0.hasPrefix("evt-") }.sorted()
        let corrupt = tempDirectory.appendingPathComponent("outbox").appendingPathComponent(sorted[0])
        try Data("not json".utf8).write(to: corrupt)

        let snapshot = try await outbox.nextBatch()
        XCTAssertEqual(snapshot.quarantinedCount, 1, "the corrupt file is quarantined on read")
        XCTAssertEqual(snapshot.events.count, 1, "delivery continues past the corrupt file")
        XCTAssertEqual(snapshot.totalPending, 1)

        // The quarantine directory holds the corrupt file, excluded from
        // pending counts but preserved for inspection.
        let quarantineDir = tempDirectory.appendingPathComponent("outbox/quarantine")
        let quarantinedFiles = try FileManager.default.contentsOfDirectory(atPath: quarantineDir.path)
        XCTAssertEqual(quarantinedFiles.count, 1)
    }

    func testRemoveAllPurgesQuarantineToo() async throws {
        let outbox = makeOutbox()
        try await outbox.prepare()
        _ = try await outbox.append([.upsert(record(1))], lane: .backfill)
        let outboxDir = tempDirectory.appendingPathComponent("outbox")
        let files = try FileManager.default.contentsOfDirectory(atPath: outboxDir.path)
        let target = files.first { $0.hasPrefix("evt-") }!
        try Data("garbage".utf8).write(to: outboxDir.appendingPathComponent(target))
        _ = try await outbox.nextBatch() // triggers quarantine
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outboxDir.appendingPathComponent("quarantine").path).count, 1)

        await outbox.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: outboxDir.appendingPathComponent("quarantine").path))
        let pending = try await outbox.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    // MARK: Lanes

    func testLiveLaneIsDeliveredBeforeBackfill() async throws {
        let outbox = makeOutbox()
        try await outbox.prepare()

        _ = try await outbox.append(
            (1...5).map { SyncChangeEvent.upsert(record($0)) },
            lane: .backfill
        )
        _ = try await outbox.append([.upsert(record(100))], lane: .live)

        let counts = try await outbox.laneCounts()
        XCTAssertEqual(counts.live, 1)
        XCTAssertEqual(counts.backfill, 5)

        // The fresh sample rides the first batch; history follows.
        let snapshot = try await outbox.nextBatch()
        XCTAssertEqual(snapshot.events.first?.eventID, SyncChangeEvent.upsert(record(100)).eventID)
        XCTAssertEqual(snapshot.totalPending, 6)
    }

    func testBackfillBatchIsToppedUpToFullSize() async throws {
        let outbox = makeOutbox()
        try await outbox.prepare()
        _ = try await outbox.append([.upsert(record(1))], lane: .live)
        _ = try await outbox.append(
            (2...50).map { SyncChangeEvent.upsert(record($0)) },
            lane: .backfill
        )

        let snapshot = try await outbox.nextBatch()
        XCTAssertEqual(snapshot.events.count, 50)
        XCTAssertEqual(snapshot.events.first?.eventID, SyncChangeEvent.upsert(record(1)).eventID)
    }

    func testLaneAssignmentSurvivesRelaunch() async throws {
        let outbox = makeOutbox()
        try await outbox.prepare()
        _ = try await outbox.append([.upsert(record(1))], lane: .live)
        _ = try await outbox.append([.upsert(record(2))], lane: .backfill)

        // A fresh instance rebuilds its index from the file names.
        let revived = makeOutbox()
        let counts = try await revived.laneCounts()
        XCTAssertEqual(counts.live, 1)
        XCTAssertEqual(counts.backfill, 1)
        let snapshot = try await revived.nextBatch()
        XCTAssertEqual(snapshot.events.first?.eventID, SyncChangeEvent.upsert(record(1)).eventID)
    }

    func testLegacyFileNamesReadAsBackfill() async throws {
        let outbox = makeOutbox()
        try await outbox.prepare()
        let event = SyncChangeEvent.upsert(record(7))
        let data = try JSONEncoder().encode(event)
        let legacyURL = tempDirectory
            .appendingPathComponent("outbox", isDirectory: true)
            .appendingPathComponent("evt-000000000000002A-\(event.eventID).json")
        try data.write(to: legacyURL)

        let revived = makeOutbox()
        let counts = try await revived.laneCounts()
        XCTAssertEqual(counts.live, 0)
        XCTAssertEqual(counts.backfill, 1)
        let snapshot = try await revived.nextBatch()
        XCTAssertEqual(snapshot.events.first?.eventID, event.eventID)
        XCTAssertEqual(snapshot.totalPending, 1)
    }

    func testAppendFailureDoesNotPoisonDedupOnReplay() async throws {
        let outbox = makeOutbox()
        try await outbox.prepare()
        let queueDirectory = tempDirectory.appendingPathComponent("outbox", isDirectory: true)

        // A read-only queue directory fails every event write (a locked
        // device does the equivalent with file protection).
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: queueDirectory.path
        )
        do {
            _ = try await outbox.append([.upsert(record(1))], lane: .live)
            XCTFail("the write should have failed")
        } catch {
            // expected
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: queueDirectory.path
        )

        // The replay after the failure must be able to append the event:
        // a poisoned dedup index here silently loses the record while the
        // checkpoint advances over it.
        _ = try await outbox.append([.upsert(record(1))], lane: .live)
        let snapshot = try await outbox.nextBatch()
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.totalPending, 1)
    }

    func testLegacyDeleteEventFileNamesReadAsBackfill() async throws {
        let outbox = makeOutbox()
        try await outbox.prepare()
        let event = deletion(9)
        let data = try JSONEncoder().encode(event)
        // Legacy layout, and the id's first hyphen-group is "del" -- the one
        // legacy shape that could be mistaken for a lane mark.
        let legacyURL = tempDirectory
            .appendingPathComponent("outbox", isDirectory: true)
            .appendingPathComponent("evt-0000000000000044-" + event.eventID + ".json")
        try data.write(to: legacyURL)

        let revived = makeOutbox()
        let counts = try await revived.laneCounts()
        XCTAssertEqual(counts.live, 0)
        XCTAssertEqual(counts.backfill, 1)
        let snapshot = try await revived.nextBatch()
        XCTAssertEqual(snapshot.events.first?.eventID, event.eventID)
    }

    func testCheckpointWithoutCaughtUpKeyDecodesAsBackfill() async throws {
        let store = makeStateStore()
        try await store.prepare()
        let scope = CategoryScope(
            destination: "https://health.example.org/v1/records",
            metric: .steps,
            generation: UUID(),
            // JSONDecoder's default date strategy decodes the JSON's raw
            // double as a timeIntervalSinceReferenceDate.
            windowStart: Date(timeIntervalSinceReferenceDate: 1_000_000)
        )
        // Pre-lane checkpoint JSON: no isCaughtUp key at all.
        let legacyJSON = "{\"scope\":{\"destination\":\"https://health.example.org/v1/records\",\"metric\":\"steps\",\"generation\":\"\(scope.generation.uuidString.lowercased())\",\"windowStart\":1000000.0},\"anchorData\":\"YTE=\",\"updatedAt\":1000060.0}"
        let url = tempDirectory.appendingPathComponent("state").appendingPathComponent("chk-steps.json")
        try legacyJSON.write(to: url, atomically: true, encoding: .utf8)

        let checkpoint = await store.loadCheckpoint(for: .steps)
        XCTAssertEqual(checkpoint?.isCaughtUp, false, "pre-lane checkpoints decode as still-backfilling")
        XCTAssertEqual(checkpoint?.scope, scope)
    }

    // MARK: Checkpoints

    func testCheckpointRoundTripPersistsAcrossStoreInstances() async throws {
        let scope = CategoryScope(
            destination: "https://health.example.org/v1/records",
            metric: .steps,
            generation: UUID(),
            windowStart: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let anchor = Data("anchor-bytes".utf8)
        let checkpoint = CategoryCheckpoint(scope: scope, anchorData: anchor, updatedAt: Date())

        let store = makeStateStore()
        try await store.prepare()
        try await store.save(checkpoint)

        let reloaded = SyncStateStore(directory: tempDirectory)
        let loaded = await reloaded.loadCheckpoint(for: .steps)
        XCTAssertEqual(loaded, checkpoint)
    }

    func testClearCheckpointRemovesOnlyThatCategory() async throws {
        let store = makeStateStore()
        try await store.prepare()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for (index, metric) in [HealthMetric.steps, .sleep].enumerated() {
            try await store.save(CategoryCheckpoint(
                scope: CategoryScope(
                    destination: "https://health.example.org/v1/records",
                    metric: metric,
                    generation: UUID(),
                    windowStart: base
                ),
                anchorData: Data("\(index)".utf8),
                updatedAt: Date()
            ))
        }

        await store.clearCheckpoint(for: .steps)

        let reloaded = SyncStateStore(directory: tempDirectory)
        let steps = await reloaded.loadCheckpoint(for: .steps)
        let sleep = await reloaded.loadCheckpoint(for: .sleep)
        XCTAssertNil(steps)
        XCTAssertNotNil(sleep)
    }

    func testRetryStateRoundTripAndBackoffProgression() async throws {
        let store = makeStateStore()
        try await store.prepare()

        var state = await store.loadRetryState()
        XCTAssertEqual(state.consecutiveFailures, 0)
        XCTAssertEqual(state.backoffSeconds(afterFailureCount: 1), 60)
        XCTAssertEqual(state.backoffSeconds(afterFailureCount: 2), 120)
        XCTAssertEqual(state.backoffSeconds(afterFailureCount: 8), 7680)
        XCTAssertEqual(state.backoffSeconds(afterFailureCount: 12), 24 * 3600)
        XCTAssertEqual(state.backoffSeconds(afterFailureCount: 30), 24 * 3600)

        state.consecutiveFailures = 3
        state.nextAttemptAt = Date(timeIntervalSince1970: 1_800_000_000)
        await store.saveRetryState(state)

        let reloaded = SyncStateStore(directory: tempDirectory)
        let loaded = await reloaded.loadRetryState()
        XCTAssertEqual(loaded.consecutiveFailures, 3)
        XCTAssertEqual(loaded.nextAttemptAt, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testUnwritablePendingScopeMarkerIsReportedNotSwallowed() async throws {
        // A path that cannot become a directory: a regular file. The store
        // cannot prepare, so the marker cannot be written — which must fail
        // loudly rather than leave a queue whose owner is unknown (the next
        // pass would read it as foreign and discard it).
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let blocker = tempDirectory.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        let store = SyncStateStore(directory: blocker)

        do {
            try await store.savePendingScope("https://health.example.org/v1/records")
            XCTFail("an unwritable ownership marker must not be reported as written")
        } catch {
            // expected
        }
    }

    func testPendingScopeRoundTripsAndClears() async throws {
        let store = makeStateStore()
        let endpoint = "https://health.example.org/v1/records"

        let initiallyUnset = await store.loadPendingScope()
        XCTAssertNil(initiallyUnset)

        try await store.savePendingScope(endpoint)
        let saved = await store.loadPendingScope()
        XCTAssertEqual(saved, endpoint)

        // A rewrite of the same value is a no-op; a different value lands.
        try await store.savePendingScope(endpoint)
        let rewritten = await store.loadPendingScope()
        XCTAssertEqual(rewritten, endpoint)

        let other = "https://other.example.org/v1/records"
        try await store.savePendingScope(other)
        let replaced = await store.loadPendingScope()
        XCTAssertEqual(replaced, other)

        await store.clearPendingScope()
        let cleared = await store.loadPendingScope()
        XCTAssertNil(cleared)
    }
}

final class SyncChangeEventTests: XCTestCase {
    private func record() -> HealthRecord {
        HealthRecord(
            metric: .steps,
            value: 42,
            unit: "count",
            startDate: Date(timeIntervalSince1970: 1_735_689_600),
            endDate: Date(timeIntervalSince1970: 1_735_689_660)
        )
    }

    func testWireEncodingMatchesContractV2Shape() throws {
        let deleted = DeletedRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!,
            metric: .sleep,
            startDate: Date(timeIntervalSince1970: 1_735_689_600),
            endDate: Date(timeIntervalSince1970: 1_735_689_660)
        )
        let data = try ChangeBatchEncoder.encode(
            batchID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")! as UUID,
            createdAt: Date(timeIntervalSince1970: 1_760_000_000),
            changes: [.upsert(record()), .delete(deleted)]
        )

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 2)
        XCTAssertNotNil(json["batchId"])
        XCTAssertNotNil(json["createdAt"])
        let changes = try XCTUnwrap(json["changes"] as? [[String: Any]])
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[0]["kind"] as? String, "upsert")
        XCTAssertNotNil(changes[0]["record"])
        XCTAssertEqual(changes[1]["kind"] as? String, "delete")
        XCTAssertEqual(changes[1]["metric"] as? String, "sleep")
        XCTAssertNotNil(changes[1]["id"])
    }

    func testChangeEventCodableRoundTrip() throws {
        let events: [SyncChangeEvent] = [.upsert(record()), .delete(DeletedRecord(
            id: UUID(),
            metric: .heartRate,
            startDate: Date(),
            endDate: Date()
        ))]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let restored = try decoder.decode([SyncChangeEvent].self, from: try encoder.encode(events))
        XCTAssertEqual(restored, events)
    }

    func testUpsertAndDeleteEventIdentitiesAreDistinct() {
        let record = self.record()
        let deleted = DeletedRecord(id: record.id, metric: record.metric, startDate: record.startDate, endDate: record.endDate)
        XCTAssertNotEqual(SyncChangeEvent.upsert(record).eventID, SyncChangeEvent.delete(deleted).eventID)
        XCTAssertEqual(SyncChangeEvent.upsert(record).sampleID, SyncChangeEvent.delete(deleted).sampleID)
    }

    func testAcknowledgmentReconciliation() {
        let full = ChangeAcknowledgment(accepted: 1, duplicates: 1, superseded: 1, appliedDeletions: 1, duplicateDeletions: 1)
        XCTAssertTrue(full.reconciles(upsertsSent: 3, deletesSent: 2))

        let short = ChangeAcknowledgment(accepted: 0, duplicates: 0, superseded: 0, appliedDeletions: 0, duplicateDeletions: 0)
        XCTAssertFalse(short.reconciles(upsertsSent: 1, deletesSent: 0))
        XCTAssertFalse(short.reconciles(upsertsSent: 0, deletesSent: 1))
        XCTAssertTrue(short.reconciles(upsertsSent: 0, deletesSent: 0))
    }

    func testAcknowledgmentDecoderRejectsBadShape() {
        XCTAssertThrowsError(try ChangeAcknowledgmentDecoder.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try ChangeAcknowledgmentDecoder.decode(Data("{\"status\":\"queued\",\"accepted\":0,\"duplicates\":0,\"superseded\":0,\"appliedDeletions\":0,\"duplicateDeletions\":0}".utf8)))
        XCTAssertThrowsError(try ChangeAcknowledgmentDecoder.decode(Data("{\"status\":\"accepted\",\"accepted\":-1,\"duplicates\":0,\"superseded\":0,\"appliedDeletions\":0,\"duplicateDeletions\":0}".utf8)))
    }
}
