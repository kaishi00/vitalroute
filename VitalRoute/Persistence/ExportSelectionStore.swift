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
        selectedMetrics = Set(rawValues.compactMap(HealthMetric.init(rawValue:)))
    }

    var hasSelection: Bool {
        !selectedMetrics.isEmpty
    }

    /// Selected categories in catalog order for deterministic payloads.
    var orderedSelection: [HealthMetric] {
        HealthMetric.allCases.filter { selectedMetrics.contains($0) }
    }

    func setMetric(_ metric: HealthMetric, selected: Bool) {
        if selected {
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
