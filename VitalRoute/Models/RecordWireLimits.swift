import Foundation

/// Client-side mirror of the receiver's structural limits
/// (`server/validation.py`). HealthKit metadata passes through unfiltered,
/// so a sample can carry values the contract cannot transport; such a
/// record would otherwise poison its whole delivery batch forever — the
/// receiver rejects batches atomically, and both sync paths retry the same
/// batch until the user intervenes. Capture paths therefore check
/// `isTransmittable` and skip-and-surface instead of queueing doomed
/// records.
///
/// The two implementations must stay in lockstep: every limit here has a
/// counterpart in `validation.py`, and the receiver's test suite pins the
/// server side.
enum RecordWireLimits {
    enum Metadata {
        static let maxEntries = 32
        static let maxKeyLength = 64
        static let maxValueLength = 512
    }

    static let maxNameLength = 256
    static let maxUnitLength = 64
    static let maxShortStringLength = 64
    static let maxFHIRIdentifierLength = 256
    static let maxCorrelationComponents = 8
    static let maxSeriesChannels = 16
    static let maxSeriesPointsPerChunk = 2048

    /// Filter form for outbox capture: deletions always pass (their metric
    /// is catalog-checked); additions are checked against the same limits.
    static func isTransmittableChangeEvent(_ event: SyncChangeEvent) -> Bool {
        switch event {
        case .delete:
            return true
        case .upsert(let record):
            return isTransmittable(record)
        }
    }

    /// True when the record can satisfy the receiver's envelope and
    /// typed-payload rules. Structural checks that require HealthKit-side
    /// knowledge (UUIDs, dates) are enforced upstream by construction.
    static func isTransmittable(_ record: HealthRecord) -> Bool {
        guard RecordKind(rawValue: record.kind.rawValue) == record.kind,
              record.kind == record.data.kind
        else { return false }
        if let source = record.sourceName, source.count > maxNameLength { return false }
        if let device = record.deviceName, device.count > maxNameLength { return false }
        let metadata = record.metadata
        if metadata.count > Metadata.maxEntries { return false }
        for (key, value) in metadata {
            if key.isEmpty || key.count > Metadata.maxKeyLength { return false }
            if value.count > Metadata.maxValueLength { return false }
        }
        return isTransmittable(record.data)
    }

    static func isTransmittable(_ data: RecordData) -> Bool {
        switch data {
        case .quantity(let payload):
            return payload.value.isFinite && isUnit(payload.unit)
        case .category(let payload):
            if payload.value < 0 { return false }
            if let name = payload.name, !isShortString(name) { return false }
            return true
        case .correlation(let payload):
            let components = payload.components
            guard (1...maxCorrelationComponents).contains(components.count) else { return false }
            return components.allSatisfy { component in
                isMetricIdentifier(component.metric)
                    && component.value.isFinite
                    && isUnit(component.unit)
            }
        case .workout(let payload):
            if !isShortString(payload.activityType) { return false }
            if payload.activityTypeRawValue < 0 { return false }
            if payload.duration.isFinite == false || payload.duration < 0 { return false }
            for optional in [payload.totalEnergyKilocalories, payload.totalDistanceMeters] {
                guard let value = optional else { continue }
                if !value.isFinite || value < 0 { return false }
            }
            return true
        case .activitySummary(let payload):
            let values = [
                payload.activeEnergyBurnedKilocalories,
                payload.activeEnergyBurnedGoalKilocalories,
                payload.exerciseTimeMinutes,
                payload.exerciseTimeGoalMinutes,
                payload.standHours,
                payload.standHoursGoal,
                payload.distanceWalkingRunningMeters,
                payload.distanceWalkingRunningGoalMeters,
            ]
            for optional in values {
                guard let value = optional else { continue }
                if !value.isFinite || value < 0 { return false }
            }
            if let day = payload.dateComponentsUTC, !isShortString(day) { return false }
            return true
        case .series(let payload):
            if !isShortString(payload.seriesType) { return false }
            guard (1...maxSeriesChannels).contains(payload.channels.count) else { return false }
            guard payload.channels.allSatisfy(isChannelName) else { return false }
            guard (1...maxSeriesPointsPerChunk).contains(payload.points.count) else { return false }
            return payload.points.allSatisfy { row in
                row.count == payload.channels.count && row.allSatisfy(\.isFinite)
            }
        case .electrocardiogram(let payload):
            if !isShortString(payload.classification) { return false }
            if let status = payload.symptomStatus, !isShortString(status) { return false }
            if let rate = payload.averageHeartRate, !rate.isFinite || rate < 0 { return false }
            if let frequency = payload.samplingFrequency, !frequency.isFinite || frequency <= 0 {
                return false
            }
            return true
        case .clinical(let payload):
            if !isShortString(payload.fhirType) { return false }
            if let identifier = payload.fhirIdentifier,
               identifier.isEmpty || identifier.count > maxFHIRIdentifierLength {
                return false
            }
            return FHIRWireBudget.isWithinBudget(payload.fhirResource)
        }
    }

    private static func isUnit(_ unit: String) -> Bool {
        !unit.isEmpty && unit.count <= maxUnitLength
    }

    private static func isShortString(_ value: String) -> Bool {
        !value.isEmpty && value.count <= maxShortStringLength
    }

    private static func isChannelName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 32
    }

    /// The receiver's metric-identifier shape: 1–64 characters, starting
    /// with an alphanumeric, then alphanumerics, dots, underscores, dashes.
    static func isMetricIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        let allowed = CharacterSet(charactersIn: "._-")
        for (index, scalar) in value.unicodeScalars.enumerated() {
            if index == 0 {
                if !(scalar.properties.isAlphabetic || scalar.properties.numericType == .decimal) {
                    return false
                }
            } else if !(scalar.properties.isAlphabetic
                || scalar.properties.numericType == .decimal
                || allowed.contains(scalar)) {
                return false
            }
        }
        return true
    }
}

/// Structural budget for clinical FHIR payloads, mirroring the receiver's
/// depth and node limits.
enum FHIRWireBudget {
    static let maxDepth = 32
    static let maxNodes = 4096

    static func isWithinBudget(_ value: FHIRJSON) -> Bool {
        guard case .object = value else { return false }
        var nodes = 0
        var stack = [(value, 0)]
        while let (current, depth) = stack.popLast() {
            if depth > maxDepth { return false }
            nodes += 1
            if nodes > maxNodes { return false }
            switch current {
            case .array(let items):
                stack.append(contentsOf: items.map { ($0, depth + 1) })
            case .object(let entries):
                for (key, nested) in entries {
                    if key.isEmpty || key.count > 256 { return false }
                    stack.append((nested, depth + 1))
                }
            case .double(let number):
                if !number.isFinite { return false }
            case .null, .bool, .int, .string:
                continue
            }
        }
        return true
    }
}
