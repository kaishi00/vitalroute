import XCTest
@testable import VitalRoute

final class RecordPagerTests: XCTestCase {
    private func record(_ id: String, offset: TimeInterval = 0) -> HealthRecord {
        HealthRecord(
            id: UUID(uuidString: id.uppercased())!,
            metric: .steps,
            value: 1,
            unit: "count",
            startDate: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            endDate: Date(timeIntervalSince1970: 1_700_000_000 + offset)
        )
    }

    func testSingleShortPageCompletesWithoutTruncation() async throws {
        let outcome = try await RecordPager.collect(maxPages: 5) {
            (anchor: String?) -> RecordPager.Page<String> in
            XCTAssertNil(anchor)
            return RecordPager.Page(
                records: [self.record("00000000-0000-0000-0000-000000000001")],
                nextAnchor: "a1",
                isFull: false
            )
        }

        XCTAssertEqual(outcome.records.count, 1)
        XCTAssertFalse(outcome.truncated)
    }

    func testMultiplePagesAreConcatenatedUntilAShortPage() async throws {
        let pages: [[HealthRecord]] = [
            (0..<3).map { self.record(String(format: "00000000-0000-0000-0000-%012d", $0)) },
            (3..<5).map { self.record(String(format: "00000000-0000-0000-0000-%012d", $0)) },
        ]
        var fetchedAnchors: [String?] = []

        let outcome = try await RecordPager.collect(maxPages: 5) {
            (anchor: String?) -> RecordPager.Page<String> in
            fetchedAnchors.append(anchor)
            let index = fetchedAnchors.count - 1
            let isFull = index < pages.count - 1
            return RecordPager.Page(
                records: pages[index],
                nextAnchor: isFull ? "anchor-\(index + 1)" : nil,
                isFull: isFull
            )
        }

        XCTAssertEqual(outcome.records.count, 5)
        XCTAssertFalse(outcome.truncated)
        XCTAssertEqual(fetchedAnchors, [nil, "anchor-1"])
    }

    func testExhaustedPageBudgetIsReportedAsTruncated() async throws {
        var fetchCount = 0
        let outcome = try await RecordPager.collect(maxPages: 3) {
            (anchor: String?) -> RecordPager.Page<String> in
            fetchCount += 1
            return RecordPager.Page(
                records: [self.record(String(format: "00000000-0000-0000-0000-%012d", fetchCount))],
                nextAnchor: "a-\(fetchCount)",
                isFull: true
            )
        }

        XCTAssertEqual(fetchCount, 3)
        XCTAssertEqual(outcome.records.count, 3)
        XCTAssertTrue(outcome.truncated)
    }

    func testNonAdvancingAnchorStopsAndReportsTruncation() async throws {
        var fetchCount = 0
        let outcome = try await RecordPager.collect(maxPages: 10) {
            (_: String?) -> RecordPager.Page<String> in
            fetchCount += 1
            // A source that keeps returning the same anchor and a full page.
            // The first fetch (against nil) "advances" to "stuck"; the second
            // fetch detects the anchor did not move and stops.
            return RecordPager.Page(
                records: [self.record("00000000-0000-0000-0000-000000000009")],
                nextAnchor: "stuck",
                isFull: true
            )
        }

        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(outcome.records.count, 1)
        XCTAssertTrue(outcome.truncated)
    }

    func testNilAnchorOnAFullPageStopsAndReportsTruncation() async throws {
        let outcome = try await RecordPager.collect(maxPages: 10) {
            (_: String?) -> RecordPager.Page<String> in
            RecordPager.Page(
                records: [self.record("00000000-0000-0000-0000-000000000002")],
                nextAnchor: nil,
                isFull: true
            )
        }

        XCTAssertEqual(outcome.records.count, 1)
        XCTAssertTrue(outcome.truncated)
    }

    func testDuplicateRecordsAcrossPagesAreDeduplicated() async throws {
        let duplicate = record("00000000-0000-0000-0000-000000000003")
        var fetchCount = 0
        let outcome = try await RecordPager.collect(maxPages: 10) {
            (_: String?) -> RecordPager.Page<String> in
            fetchCount += 1
            let isFull = fetchCount <= 2
            return RecordPager.Page(
                records: [duplicate],
                nextAnchor: isFull ? "a-\(fetchCount)" : nil,
                isFull: isFull
            )
        }

        XCTAssertEqual(outcome.records.count, 1)
        XCTAssertFalse(outcome.truncated)
    }

    func testCancellationBetweenPagesThrowsCancellationError() async throws {
        // The first page parks inside the gate so the test can cancel while
        // the pager is deterministically between its checkCancellation point
        // and the next page.
        let gate = PageGate()
        let record = self.record("00000000-0000-0000-0000-000000000004")
        let task = Task {
            try await RecordPager.collect(maxPages: 10) {
                (_: String?) -> RecordPager.Page<String> in
                await gate.wait()
                return RecordPager.Page(records: [record], nextAnchor: "next", isFull: true)
            }
        }

        while !gate.isEntered {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        task.cancel()
        gate.open()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected: the loop checks cancellation before each page.
        }
    }
}

/// Parks the first page fetch until the test releases it, giving the
/// cancellation test a deterministic interleave point.
private final class PageGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var opened = false

    var isEntered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }

    func wait() async {
        lock.lock()
        entered = true
        while !opened {
            lock.unlock()
            try? await Task.sleep(nanoseconds: 2_000_000)
            lock.lock()
        }
        lock.unlock()
    }

    func open() {
        lock.lock()
        opened = true
        lock.unlock()
    }
}
