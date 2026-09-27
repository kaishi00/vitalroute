import Foundation
import Observation

/// The categories the user opted into exporting. Selection is explicit
/// (empty until the user acts), stored as plain preference data — category
/// names only, never health records — and is distinct from HealthKit
/// authorization: enabling a toggle chooses what to export, it does not grant
/// (or imply) read access.
@MainActor
@Observable
final class ExportSelectionStore {
    @ObservationIgnored private let defaults: UserDefaults
    private let storageKey = "export.selectedMetrics"

    private(set) var selectedMetrics: Set<HealthMetric>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let rawValues = defaults.stringArray(forKey: storageKey) ?? []
        // Only user-selectable metrics are valid selections; unknown
        // identifiers and component-only metrics (which exist to describe
        // parts of other records) are dropped at load.
        selectedMetrics = Set(rawValues.compactMap(HealthMetric.init(rawValue:)))
            .filter { $0.descriptor.userSelectable }
    }

    var hasSelection: Bool {
        !selectedMetrics.isEmpty
    }

    /// Selected categories in catalog order for deterministic payloads.
    var orderedSelection: [HealthMetric] {
        MetricCatalog.selectableMetrics.map(\.metric).filter { selectedMetrics.contains($0) }
    }

    func setMetric(_ metric: HealthMetric, selected: Bool) {
        if selected {
            // Component-only metrics are never user selections; the
            // load-time filter would drop them anyway, so refusing here
            // keeps the invariant at the write site too. Deselection is
            // always allowed so stale persisted values can be cleaned up.
            guard metric.descriptor.userSelectable else { return }
            selectedMetrics.insert(metric)
        } else {
            selectedMetrics.remove(metric)
        }
        persist()
    }

    private func persist() {
        defaults.set(orderedSelection.map(\.rawValue), forKey: storageKey)
    }
}
