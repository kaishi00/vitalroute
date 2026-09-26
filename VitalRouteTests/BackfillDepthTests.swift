import XCTest
@testable import VitalRoute

final class BackfillDepthTests: XCTestCase {

    func testWindowStartsOrderByDepth() {
        let now = Date()
        let seven = BackfillDepth.sevenDays.windowStart(from: now)
        let thirty = BackfillDepth.thirtyDays.windowStart(from: now)
        let ninety = BackfillDepth.ninetyDays.windowStart(from: now)
        let year = BackfillDepth.oneYear.windowStart(from: now)
        XCTAssertEqual(.distantPast, BackfillDepth.allRecords.windowStart(from: now))
        XCTAssertLessThan(year, ninety)
        XCTAssertLessThan(ninety, thirty)
        XCTAssertLessThan(thirty, seven)
        XCTAssertLessThan(seven, now)
    }

    func testStorageRoundTripAndFallback() {
        let suite = "backfill-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(BackfillDepth.stored(in: defaults), .sevenDays)
        BackfillDepth.store(.oneYear, in: defaults)
        XCTAssertEqual(BackfillDepth.stored(in: defaults), .oneYear)
        // An unknown value (e.g. after a downgrade) must fall back to the
        // conservative default rather than widening anything.
        defaults.set("forever-and-a-day", forKey: BackfillDepth.storageKey)
        XCTAssertEqual(BackfillDepth.stored(in: defaults), .sevenDays)
    }
}
