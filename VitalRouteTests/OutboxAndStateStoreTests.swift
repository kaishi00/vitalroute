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

        _ = try await outbox.append([.upsert(record(1)), .upsert(record(2))])
        // Crash-replay of the same events must not duplicate.
        _ = try await outbox.append([.upsert(record(2)), .upsert(record(3))])

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
        _ = try await outbox.append(events)

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
        _ = try await outbox.append([.upsert(record(1)), deletion(2), .upsert(record(3))])

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
        ])

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
        _ = try await outbox.append(events)

        let atCapacity = try await outbox.isAtCapacity()
        XCTAssertTrue(atCapacity)

        // Drain one batch; below capacity again.
        let batch = try await outbox.nextBatch()
        await outbox.remove(eventIDs: batch.events.map(\.eventID))
        let drained = try await outbox.isAtCapacity()
        XCTAssertFalse(drained)
    }

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
        XCTAssertEqual(state.backoffSeconds(afterFailureCount: 8), 24 * 3600)
        XCTAssertEqual(state.backoffSeconds(afterFailureCount: 30), 24 * 3600)

        state.consecutiveFailures = 3
        state.nextAttemptAt = Date(timeIntervalSince1970: 1_800_000_000)
        await store.saveRetryState(state)

        let reloaded = SyncStateStore(directory: tempDirectory)
        let loaded = await reloaded.loadRetryState()
        XCTAssertEqual(loaded.consecutiveFailures, 3)
        XCTAssertEqual(loaded.nextAttemptAt, Date(timeIntervalSince1970: 1_800_000_000))
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
