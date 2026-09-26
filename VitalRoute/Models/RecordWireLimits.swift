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
/// The two implementations must stay in lockstep, in BOTH directions:
/// looser here means the receiver still rejects the batch (the failure
/// this type exists to prevent); stricter here means silently dropping
/// records the receiver would have accepted.
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
    /// Mirror of the receiver's canonical data_json cap
    /// (`_MAX_DATA_JSON_BYTES`): bounds byte length, which the FHIR node /
    /// depth budget alone does not.
    static let maxEncodedDataBytes = 1_048_576
    static let maxInt32 = Int(Int32.max)

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
    /// knowledge (UUIDs, dates) are enforced upstream by construction; the
    /// metric identifier is a catalog-minted `HealthMetric`, so only
    /// free-form strings and payload content need mirroring here.
    static func isTransmittable(_ record: HealthRecord) -> Bool {
        guard record.kind == record.data.kind else { return false }
        if let source = record.sourceName, source.count > maxNameLength { return false }
        if let device = record.deviceName, device.count > maxNameLength { return false }
        let metadata = record.metadata
        if metadata.count > Metadata.maxEntries { return false }
        for (key, value) in metadata {
            if key.isEmpty || key.count > Metadata.maxKeyLength { return false }
            if value.count > Metadata.maxValueLength { return false }
        }
        guard isTransmittable(record.data) else { return false }
        // The receiver caps the CANONICAL data JSON it re-serializes with
        // Python's ensure_ascii escaping (non-ASCII scalars become 6-byte
        // uXXXX escapes, astral ones 12), which is not our UTF-8 byte
        // count. Only clinical (free-form FHIR text) and series (many
        // numeric rows) can approach the cap; every other kind is bounded
        // far below it by short-string limits, so the encoding cost is
        // paid only where it can matter. An unencodable payload can never
        // be delivered.
        switch record.data {
        case .clinical, .series:
            guard let encoded = try? JSONEncoder().encode(record.data) else {
                return false
            }
            return canonicalByteCount(of: encoded) <= maxEncodedDataBytes
        default:
            return true
        }
    }

    /// Upper bound of the byte length the receiver measures: Python's
    /// json.dumps with ensure_ascii escapes every non-ASCII scalar
    /// (6 bytes; astral surrogate pairs, 12) and expands quotes,
    /// backslashes, and control characters. ASCII payloads measure
    /// identically to UTF-8; non-ASCII measures conservatively larger than
    /// our encoding, so the mirror errs toward rejecting rather than
    /// toward poisoning a batch server-side.
    static func canonicalByteCount(of encoded: Data) -> Int {
        var count = 0
        var index = 0
        let bytes = [UInt8](encoded)
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case 0x80...0xBF:
                // UTF-8 continuation byte: its lead byte already accounted
                // for the whole escaped scalar.
                break
            case 0xC2...0xDF:
                count += 6 // 2-byte scalar -> short unicode escape
            case 0xE0...0xEF:
                count += 6 // 3-byte scalar -> short unicode escape
            case 0xF0...0xF4:
                count += 12 // astral scalar -> surrogate pair escape
            case 0x5C:
                count += 2 // backslash: canonical form always escapes it
            case 0x22:
                // Structural quotes cost 1, escaped quotes 2; counting 1
                // and charging the escape lead covers both.
                count += 1
            default:
                // Printable ASCII counts 1; control characters escape to
                // at most 6 bytes.
                count += (byte >= 0x20 && byte <= 0x7E) ? 1 : 6
            }
            index += 1
        }
        return count
    }

    static func isTransmittable(_ data: RecordData) -> Bool {
        switch data {
        case .quantity(let payload):
            return payload.value.isFinite && isUnit(payload.unit)
        case .category(let payload):
            if payload.value < 0 || payload.value > maxInt32 { return false }
            if let name = payload.name, name.count > maxShortStringLength { return false }
            return true
        case .correlation(let payload):
            let components = payload.components
            guard (1...maxCorrelationComponents).contains(components.count) else { return false }
            return components.allSatisfy { component in
                isASCIIIdentifier(component.metric, maxLength: 64)
                    && component.value.isFinite
                    && isUnit(component.unit)
            }
        case .workout(let payload):
            if !isShortString(payload.activityType) { return false }
            if payload.activityTypeRawValue < 0 || payload.activityTypeRawValue > maxInt32 {
                return false
            }
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
            if payload.chunkIndex < 0 || payload.chunkIndex > 1_000_000 { return false }
            guard (1...maxSeriesChannels).contains(payload.channels.count) else { return false }
            guard payload.channels.allSatisfy({ isASCIIIdentifier($0, maxLength: 32) }) else {
                return false
            }
            guard (1...maxSeriesPointsPerChunk).contains(payload.points.count) else { return false }
            return payload.points.allSatisfy { row in
                row.count == payload.channels.count && row.allSatisfy(\.isFinite)
            }
        case .electrocardiogram(let payload):
            if !isShortString(payload.classification) { return false }
            if let status = payload.symptomStatus, !isShortString(status) { return false }
            if let raw = payload.classificationRawValue, raw < 0 || raw > maxInt32 { return false }
            if let raw = payload.symptomStatusRawValue, raw < 0 || raw > maxInt32 { return false }
            if let rate = payload.averageHeartRate, !rate.isFinite || rate < 0 { return false }
            if let frequency = payload.samplingFrequency, !frequency.isFinite || frequency <= 0 {
                return false
            }
            return true
        case .clinical(let payload):
            if !isShortString(payload.fhirType) { return false }
            if let identifier = payload.fhirIdentifier,
                identifier.count > maxFHIRIdentifierLength {
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

    /// The receiver's identifier shape, ASCII-only:
    /// `^[A-Za-z0-9][A-Za-z0-9._-]{0,maxLength-1}$`.
    static func isASCIIIdentifier(_ value: String, maxLength: Int) -> Bool {
        guard !value.isEmpty, value.count <= maxLength else { return false }
        let extra = CharacterSet(charactersIn: "._-")
        for (index, scalar) in value.unicodeScalars.enumerated() {
            let isASCIIAlphanumeric = (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)
            if index == 0 {
                if !isASCIIAlphanumeric { return false }
            } else if !(isASCIIAlphanumeric || extra.contains(scalar)) {
                return false
            }
        }
        return true
    }
}

/// Structural budget for clinical FHIR payloads, mirroring the receiver's
/// depth, node, and key limits. Byte length is bounded separately by
/// `RecordWireLimits.maxEncodedDataBytes`.
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
