import Foundation

/// One anchor-driven page of a HealthKit read. Callers persist `nextAnchor`
/// only after the page has been durably handled and keep paging while
/// `isFull`; the paging loop itself lives with its caller so budgets and
/// resumption are explicit. Page records are mapped values (Sendable), not
/// the HealthKit objects behind them.
enum RecordPager {
    struct Page<Record: Equatable, Anchor: Equatable> {
        let records: [Record]
        let nextAnchor: Anchor?
        let isFull: Bool
    }
}
