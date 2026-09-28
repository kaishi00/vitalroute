import Foundation

/// One health record: a common envelope plus a typed `data` payload.
///
/// The envelope carries the fields every record shares — identity, metric,
/// structure (`kind`), interval, provenance, and string annotations — while
/// `data` carries everything structural, discriminated by its own `type`
/// which must equal `kind`. Record identity is the Apple Health sample UUID
/// (or the client-derived deterministic UUID of a series chunk), which is
/// what makes delivery idempotent end to end.
///
/// `metric` and `kind` are deliberately independent axes: a metric whose
/// records continue into a series emits a parent record of its own kind
/// plus chunk records of kind `.series` under the same metric. The
/// descriptor's `recordKind` is the primary kind for ordinary metrics, not
/// a constraint.
struct HealthRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let metric: HealthMetric
    let kind: RecordKind
    let startDate: Date
    let endDate: Date
    let sourceName: String?
    let deviceName: String?
    let metadata: [String: String]
    let data: RecordData

    init(
        id: UUID = UUID(),
        metric: HealthMetric,
        startDate: Date,
        endDate: Date,
        sourceName: String? = nil,
        deviceName: String? = nil,
        metadata: [String: String] = [:],
        data: RecordData
    ) {
        self.id = id
        self.metric = metric
        self.kind = data.kind
        self.startDate = startDate
        self.endDate = endDate
        self.sourceName = sourceName
        self.deviceName = deviceName
        self.metadata = metadata
        self.data = data
    }

    /// Coding is manual so the kind/data invariant is enforced on decode:
    /// a payload whose `type` disagrees with its `kind` is malformed and
    /// must be rejected rather than stored.
    private enum CodingKeys: String, CodingKey {
        case id, metric, kind, startDate, endDate, sourceName, deviceName, metadata, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        metric = try container.decode(HealthMetric.self, forKey: .metric)
        kind = try container.decode(RecordKind.self, forKey: .kind)
        data = try container.decode(RecordData.self, forKey: .data)
        guard kind == data.kind else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Record kind \(kind.rawValue) does not match its data type \(data.kind.rawValue)."
            ))
        }
        startDate = try container.decode(Date.self, forKey: .startDate)
        endDate = try container.decode(Date.self, forKey: .endDate)
        sourceName = try container.decodeIfPresent(String.self, forKey: .sourceName)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
        metadata = try container.decode([String: String].self, forKey: .metadata)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(metric, forKey: .metric)
        try container.encode(kind, forKey: .kind)
        try container.encode(startDate, forKey: .startDate)
        try container.encode(endDate, forKey: .endDate)
        try container.encodeIfPresent(sourceName, forKey: .sourceName)
        try container.encodeIfPresent(deviceName, forKey: .deviceName)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(data, forKey: .data)
    }
}

extension HealthRecord {
    /// A short, human-readable summary for dashboards. Formatting generally
    /// follows the payload kind; blood pressure correlations use metric
    /// identity to label their systolic and diastolic components.
    var displayValue: String {
        switch data {
        case .quantity(let payload):
            if payload.unit == "s" {
                return Self.durationLabel(payload.value)
            }
            if payload.unit == "1" {
                return payload.value.formatted(.number.precision(.fractionLength(0...1)))
            }
            return "\(payload.value.formatted(.number.precision(.fractionLength(0...1)))) \(payload.unit)"
        case .category(let payload):
            return payload.name.map { Self.humanizedCategoryName($0) } ?? "value \(payload.value)"
        case .correlation(let payload):
            if metric.rawValue == HealthMetric.bloodPressure.rawValue {
                return Self.bloodPressureDisplayValue(payload.components)
            }
            return payload.components
                .map { "\($0.value.formatted(.number.precision(.fractionLength(0...1)))) \($0.unit)" }
                .joined(separator: " / ")
        case .workout(let payload):
            return "\(Self.humanizedCategoryName(payload.activityType)) · \(Self.durationLabel(payload.duration))"
        case .activitySummary(let payload):
            if let minutes = payload.exerciseTimeMinutes {
                return "\(max(0, Self.clampedInt(minutes))) min exercise"
            }
            return "Daily summary"
        case .series(let payload):
            return "\(payload.points.count) points · chunk \(payload.chunkIndex)"
        case .electrocardiogram(let payload):
            return Self.humanizedCategoryName(payload.classification)
        case .clinical(let payload):
            return payload.fhirType
        }
    }

    private static func bloodPressureDisplayValue(_ components: [CorrelationComponent]) -> String {
        let systolic = components.first { $0.metric == HealthMetric.bloodPressureSystolic.rawValue }
        let diastolic = components.first { $0.metric == HealthMetric.bloodPressureDiastolic.rawValue }
        switch (systolic, diastolic) {
        case let (.some(sys), .some(dia)):
            return "Systolic \(sys.value.formatted(.number.precision(.fractionLength(0...1)))) \(sys.unit) · Diastolic \(dia.value.formatted(.number.precision(.fractionLength(0...1)))) \(dia.unit)"
        case let (.some(sys), .none):
            return "Systolic \(sys.value.formatted(.number.precision(.fractionLength(0...1)))) \(sys.unit) · Diastolic unavailable"
        case let (.none, .some(dia)):
            return "Systolic unavailable · Diastolic \(dia.value.formatted(.number.precision(.fractionLength(0...1)))) \(dia.unit)"
        case (.none, .none):
            return "Blood pressure reading unavailable"
        }
    }

    /// Keep short intervals legible, while representing longer durations in
    /// minutes. The input is intentionally sanitized here because display
    /// paths can see unvalidated records (including NaN and infinities).
    static func durationLabel(_ seconds: Double) -> String {
        guard !seconds.isNaN, seconds > 0 else { return "0 sec" }
        if seconds < 60 {
            return "\(clampedInt(seconds)) sec"
        }
        let wholeMinutes = clampedInt(seconds / 60)
        guard wholeMinutes < Int.max else { return "\(Int.max) min" }
        let minutes = (seconds / 60).formatted(.number.precision(.fractionLength(0...1)))
        return "\(minutes) min"
    }

    /// The Int init without the trap: values beyond Int's range (including
    /// ±infinity) clamp to the nearest bound; only NaN collapses to zero.
    static func clampedInt(_ value: Double) -> Int {
        if value.isNaN { return 0 }
        if value >= Double(Int.max) { return Int.max }
        if value <= Double(Int.min) { return Int.min }
        return Int(value)
    }

    /// "asleepREM" -> "Asleep REM"; "sinusRhythm" -> "Sinus rhythm".
    /// Splits at lower→upper boundaries and before an acronym run's last
    /// upper (so consecutive capitals stay together), and leaves an
    /// all-capitals word's casing alone.
    static func humanizedCategoryName(_ rawName: String) -> String {
        let spaced = rawName
            .replacingOccurrences(
                of: "([a-z0-9])([A-Z])",
                with: "$1 $2",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "([A-Z])([A-Z][a-z])",
                with: "$1 $2",
                options: .regularExpression
            )
        let words = spaced.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return rawName }
        // An all-capitals word keeps its casing wherever it appears; other
        // words normalize (first capitalized, rest lowercased).
        func cased(_ word: String) -> String {
            (word.count > 1 && word == word.uppercased()) ? word : word.lowercased()
        }
        let first = words[0].count > 1 && words[0] == words[0].uppercased()
            ? words[0]
            : words[0].capitalized
        let rest = words.dropFirst().map(cased).joined(separator: " ")
        return rest.isEmpty ? first : "\(first) \(rest)"
    }
}
