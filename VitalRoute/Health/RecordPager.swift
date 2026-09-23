import Foundation

/// Generic anchor-driven paging for complete, bounded HealthKit reads.
///
/// The loop advances an opaque anchor (HKQueryAnchor in production, any
/// `Equatable` in tests) until a page comes back short, and treats two hard
/// stops — a page budget exhausted, or an anchor that cannot advance — as
/// truncation that callers must surface, never as success.
enum RecordPager {
    struct Page<Anchor: Equatable> {
        let records: [HealthRecord]
        let nextAnchor: Anchor?
        let isFull: Bool
    }

    static func collect<Anchor: Equatable>(
        maxPages: Int,
        fetch: (Anchor?) async throws -> Page<Anchor>
    ) async throws -> (records: [HealthRecord], truncated: Bool) {
        precondition(maxPages >= 1, "maxPages must allow at least one page")

        var collected: [HealthRecord] = []
        var seenIDs = Set<UUID>()
        var anchor: Anchor?
        var truncated = false

        for pageIndex in 0..<maxPages {
            try Task.checkCancellation()
            let page = try await fetch(anchor)

            // An anchor that fails to advance must not produce an unbounded
            // loop; deduplication keeps the accumulator honest if a source
            // ever replays samples.
            for record in page.records where !seenIDs.contains(record.id) {
                seenIDs.insert(record.id)
                collected.append(record)
            }

            guard page.isFull else {
                return (collected, false)
            }
            guard let next = page.nextAnchor, next != anchor else {
                return (collected, true)
            }
            anchor = next
            if pageIndex == maxPages - 1 {
                truncated = true
            }
        }
        return (collected, truncated)
    }
}
