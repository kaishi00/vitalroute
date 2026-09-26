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
    /// A short, human-readable summary for dashboards. Formatting lives on
    /// the payload kind — never on the metric — so new metrics of an
    /// existing kind display correctly with zero UI work.
    var displayValue: String {
        switch data {
        case .quantity(let payload):
            if payload.unit == "s" {
                return "\(Int(payload.value / 60)) min"
            }
            return "\(payload.value.formatted(.number.precision(.fractionLength(0...1)))) \(payload.unit)"
        case .category(let payload):
            return payload.name.map { Self.humanizedCategoryName($0) } ?? "value \(payload.value)"
        case .correlation(let payload):
            return payload.components
                .map { "\($0.value.formatted(.number.precision(.fractionLength(0...1)))) \($0.unit)" }
                .joined(separator: " / ")
        case .workout(let payload):
            let minutes = Int(payload.duration / 60)
            return "\(Self.humanizedCategoryName(payload.activityType)) · \(minutes) min"
        case .activitySummary(let payload):
            if let minutes = payload.exerciseTimeMinutes {
                return "\(Int(minutes)) min exercise"
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

    /// "asleepREM" -> "Asleep REM"; "sinusRhythm" -> "Sinus rhythm".
    static func humanizedCategoryName(_ rawName: String) -> String {
        let words = rawName
            .replacingOccurrences(of: "([A-Z])", with: " $1", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
        guard !words.isEmpty else { return rawName }
        let first = words[0].capitalized
        let rest = words.dropFirst().joined(separator: " ").lowercased()
        return rest.isEmpty ? first : "\(first) \(rest)"
    }
}
