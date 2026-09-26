import Foundation

/// One anchor-driven page of a HealthKit read. Callers persist `nextAnchor`
/// only after the page has been durably handled and keep paging while
/// `isFull`; the paging loop itself lives with its caller so budgets and
/// resumption are explicit.
enum RecordPager {
    struct Page<Anchor: Equatable> {
        let records: [HealthRecord]
        let nextAnchor: Anchor?
        let isFull: Bool
    }
}
