import Foundation
import Observation

/// How far back a sync reaches when a category scope is (re)bootstrapped.
///
/// The depth only shapes the scope's FIXED initial window start — it never
/// moves an existing predicate, because a HealthKit anchor is only valid for
/// the exact predicate it was produced with. Deepening the depth mints a new
/// scope generation (a fresh bootstrap that reaches further back); making it
/// shallower leaves existing scopes untouched, since their data is already
/// captured and their predicates remain valid.
enum BackfillDepth: String, CaseIterable, Codable, Identifiable {
    static let storageKey = "sync.backfillDepth"

    case sevenDays
    case thirtyDays
    case ninetyDays
    case oneYear
    case allRecords

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sevenDays: return "Last 7 days"
        case .thirtyDays: return "Last 30 days"
        case .ninetyDays: return "Last 90 days"
        case .oneYear: return "Last year"
        case .allRecords: return "All records"
        }
    }

    /// The fixed window start for a scope created at `reference` with this
    /// depth. `.allRecords` uses the distant past so one uniform predicate
    /// covers the entire HealthKit history.
    func windowStart(from reference: Date, calendar: Calendar = .current) -> Date {
        // If calendar arithmetic ever fails, fall back to the conservative
        // default window — never a zero-width "reference" window.
        let fallback = calendar.date(byAdding: .day, value: -7, to: reference) ?? reference
        switch self {
        case .sevenDays:
            return fallback
        case .thirtyDays:
            return calendar.date(byAdding: .day, value: -30, to: reference) ?? fallback
        case .ninetyDays:
            return calendar.date(byAdding: .day, value: -90, to: reference) ?? fallback
        case .oneYear:
            // Calendar-year arithmetic (a Feb 29 anchor shifts a day).
            return calendar.date(byAdding: .year, value: -1, to: reference) ?? fallback
        case .allRecords:
            return .distantPast
        }
    }

    /// Reads the persisted preference; unknown or missing values fall back
    /// to the conservative default so an app downgrade never widens a sync.
    static func stored(in defaults: UserDefaults) -> BackfillDepth {
        guard let raw = defaults.string(forKey: storageKey),
              let depth = BackfillDepth(rawValue: raw) else {
            return .sevenDays
        }
        return depth
    }

    static func store(_ depth: BackfillDepth, in defaults: UserDefaults) {
        defaults.set(depth.rawValue, forKey: storageKey)
    }
}

/// Observable wrapper for the Settings picker. Not sensitive data — a plain
/// defaults-backed preference, unlike endpoints, keys, and selections.
@MainActor
@Observable
final class BackfillPreferenceStore {
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var depth: BackfillDepth

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.depth = BackfillDepth.stored(in: defaults)
    }

    func set(_ newValue: BackfillDepth) {
        depth = newValue
        BackfillDepth.store(newValue, in: defaults)
    }
}
