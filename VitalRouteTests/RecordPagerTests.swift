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
        let outcome = try await RecordPager.collect(maxPages: 5) { anchor in
            XCTAssertNil(anchor)
            return RecordPager.Page(records: [self.record("00000000-0000-0000-0000-000000000001")], nextAnchor: "a1", isFull: false)
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

        let outcome = try await RecordPager.collect(maxPages: 5) { anchor in
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
        let outcome = try await RecordPager.collect(maxPages: 3) { anchor in
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
        let outcome = try await RecordPager.collect(maxPages: 10) { anchor in
            fetchCount += 1
            // A source that keeps returning the same anchor and a full page.
            return RecordPager.Page(
                records: [self.record("00000000-0000-0000-0000-000000000009")],
                nextAnchor: "stuck",
                isFull: true
            )
        }

        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(outcome.records.count, 1)
        XCTAssertTrue(outcome.truncated)
    }

    func testNilAnchorOnAFullPageStopsAndReportsTruncation() async throws {
        let outcome = try await RecordPager.collect(maxPages: 10) { _ in
            RecordPager.Page(records: [self.record("00000000-0000-0000-0000-000000000002")], nextAnchor: nil, isFull: true)
        }

        XCTAssertEqual(outcome.records.count, 1)
        XCTAssertTrue(outcome.truncated)
    }

    func testDuplicateRecordsAcrossPagesAreDeduplicated() async throws {
        let duplicate = record("00000000-0000-0000-0000-000000000003")
        var fetchCount = 0
        let outcome = try await RecordPager.collect(maxPages: 10) { anchor in
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
        let expectation = expectation(description: "page fetched")
        let task = Task {
            try await RecordPager.collect(maxPages: 10) { anchor in
                expectation.fulfill()
                return RecordPager.Page(records: [self.record("00000000-0000-0000-0000-000000000004")], nextAnchor: "next", isFull: true)
            }
        }
        await fulfillment(of: [expectation])
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected: the loop checks cancellation before each page.
        }
    }
}
