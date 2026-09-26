import Foundation

/// How a record's information is structurally represented. `kind` answers
/// "what shape is this data", while the record's `metric` answers "what
/// health information it is" — the two are independent axes, and the
/// receiver validates `kind` against the typed `data` payload, never
/// against the metric.
enum RecordKind: String, Codable, CaseIterable, Sendable, Hashable {
    case quantity
    case category
    case correlation
    case workout
    case activitySummary
    case series
    case electrocardiogram
    case clinical
}

/// A scalar sample: one number in a physical unit.
struct QuantityData: Codable, Equatable, Sendable {
    let value: Double
    let unit: String

    private enum CodingKeys: String, CodingKey { case type, value, unit }

    static let wireType = RecordKind.quantity.rawValue

    init(value: Double, unit: String) {
        self.value = value
        self.unit = unit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .type) == Self.wireType else {
            throw Self.typeMismatch(decoder)
        }
        value = try container.decode(Double.self, forKey: .value)
        unit = try container.decode(String.self, forKey: .unit)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.wireType, forKey: .type)
        try container.encode(value, forKey: .value)
        try container.encode(unit, forKey: .unit)
    }

    static func typeMismatch(_ decoder: Decoder) -> DecodingError {
        .dataCorrupted(DecodingError.Context(
            codingPath: decoder.codingPath,
            debugDescription: "Data payload type does not match its record kind."
        ))
    }
}

/// A categorical sample, e.g. a sleep stage. `value` is the client's raw
/// category value; `name` is the stable value name when the client can map
/// one (for example "asleepREM").
struct CategoryData: Codable, Equatable, Sendable {
    let value: Int
    let name: String?

    private enum CodingKeys: String, CodingKey { case type, value, name }

    static let wireType = RecordKind.category.rawValue

    init(value: Int, name: String?) {
        self.value = value
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .type) == Self.wireType else {
            throw Self.typeMismatch(decoder)
        }
        value = try container.decode(Int.self, forKey: .value)
        name = try container.decodeIfPresent(String.self, forKey: .name)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.wireType, forKey: .type)
        try container.encode(value, forKey: .value)
        try container.encodeIfPresent(name, forKey: .name)
    }
}

/// One measurement inside a correlation, e.g. the systolic reading of a
/// blood pressure sample.
struct CorrelationComponent: Codable, Equatable, Sendable {
    let metric: String
    let value: Double
    let unit: String
}

/// One sample structurally tying several measurements together, e.g. a
/// blood pressure reading with its systolic and diastolic components.
struct CorrelationData: Codable, Equatable, Sendable {
    struct ComponentLimit {
        static let minCount = 1
        static let maxCount = 8
    }

    let components: [CorrelationComponent]

    private enum CodingKeys: String, CodingKey { case type, components }

    static let wireType = RecordKind.correlation.rawValue

    init(components: [CorrelationComponent]) {
        self.components = components
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .type) == Self.wireType else {
            throw QuantityData.typeMismatch(decoder)
        }
        components = try container.decode([CorrelationComponent].self, forKey: .components)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.wireType, forKey: .type)
        try container.encode(components, forKey: .components)
    }
}

/// A workout with structured details. Energy and distance are pre-converted
/// to their canonical units by the extractor, so consumers never re-derive
/// unit semantics.
struct WorkoutData: Codable, Equatable, Sendable {
    /// Stable activity-type name (e.g. "running"); the raw HealthKit enum
    /// value travels alongside it so fidelity never depends on the name.
    let activityType: String
    let activityTypeRawValue: Int
    let duration: TimeInterval
    let totalEnergyKilocalories: Double?
    let totalDistanceMeters: Double?

    private enum CodingKeys: String, CodingKey {
        case type, activityType, activityTypeRawValue, duration
        case totalEnergyKilocalories, totalDistanceMeters
    }

    static let wireType = RecordKind.workout.rawValue

    init(
        activityType: String,
        activityTypeRawValue: Int,
        duration: TimeInterval,
        totalEnergyKilocalories: Double?,
        totalDistanceMeters: Double?
    ) {
        self.activityType = activityType
        self.activityTypeRawValue = activityTypeRawValue
        self.duration = duration
        self.totalEnergyKilocalories = totalEnergyKilocalories
        self.totalDistanceMeters = totalDistanceMeters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .type) == Self.wireType else {
            throw QuantityData.typeMismatch(decoder)
        }
        activityType = try container.decode(String.self, forKey: .activityType)
        activityTypeRawValue = try container.decode(Int.self, forKey: .activityTypeRawValue)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        totalEnergyKilocalories = try container.decodeIfPresent(Double.self, forKey: .totalEnergyKilocalories)
        totalDistanceMeters = try container.decodeIfPresent(Double.self, forKey: .totalDistanceMeters)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.wireType, forKey: .type)
        try container.encode(activityType, forKey: .activityType)
        try container.encode(activityTypeRawValue, forKey: .activityTypeRawValue)
        try container.encode(duration, forKey: .duration)
        try container.encodeIfPresent(totalEnergyKilocalories, forKey: .totalEnergyKilocalories)
        try container.encodeIfPresent(totalDistanceMeters, forKey: .totalDistanceMeters)
    }
}

/// A daily activity summary. Quantities are pre-converted to canonical
/// units; every field is optional because HealthKit summaries are sparse.
struct ActivitySummaryData: Codable, Equatable, Sendable {
    let activeEnergyBurnedKilocalories: Double?
    let activeEnergyBurnedGoalKilocalories: Double?
    let exerciseTimeMinutes: Double?
    let exerciseTimeGoalMinutes: Double?
    let standHours: Double?
    let standHoursGoal: Double?
    let distanceWalkingRunningMeters: Double?
    let distanceWalkingRunningGoalMeters: Double?
    /// The summary day as an ISO date string ("2026-09-25"), evaluated in
    /// the calendar HealthKit provided.
    let dateComponentsUTC: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case activeEnergyBurnedKilocalories, activeEnergyBurnedGoalKilocalories
        case exerciseTimeMinutes, exerciseTimeGoalMinutes
        case standHours, standHoursGoal
        case distanceWalkingRunningMeters, distanceWalkingRunningGoalMeters
        case dateComponentsUTC
    }

    static let wireType = RecordKind.activitySummary.rawValue

    init(
        activeEnergyBurnedKilocalories: Double? = nil,
        activeEnergyBurnedGoalKilocalories: Double? = nil,
        exerciseTimeMinutes: Double? = nil,
        exerciseTimeGoalMinutes: Double? = nil,
        standHours: Double? = nil,
        standHoursGoal: Double? = nil,
        distanceWalkingRunningMeters: Double? = nil,
        distanceWalkingRunningGoalMeters: Double? = nil,
        dateComponentsUTC: String? = nil
    ) {
        self.activeEnergyBurnedKilocalories = activeEnergyBurnedKilocalories
        self.activeEnergyBurnedGoalKilocalories = activeEnergyBurnedGoalKilocalories
        self.exerciseTimeMinutes = exerciseTimeMinutes
        self.exerciseTimeGoalMinutes = exerciseTimeGoalMinutes
        self.standHours = standHours
        self.standHoursGoal = standHoursGoal
        self.distanceWalkingRunningMeters = distanceWalkingRunningMeters
        self.distanceWalkingRunningGoalMeters = distanceWalkingRunningGoalMeters
        self.dateComponentsUTC = dateComponentsUTC
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .type) == Self.wireType else {
            throw QuantityData.typeMismatch(decoder)
        }
        activeEnergyBurnedKilocalories = try container.decodeIfPresent(Double.self, forKey: .activeEnergyBurnedKilocalories)
        activeEnergyBurnedGoalKilocalories = try container.decodeIfPresent(Double.self, forKey: .activeEnergyBurnedGoalKilocalories)
        exerciseTimeMinutes = try container.decodeIfPresent(Double.self, forKey: .exerciseTimeMinutes)
        exerciseTimeGoalMinutes = try container.decodeIfPresent(Double.self, forKey: .exerciseTimeGoalMinutes)
        standHours = try container.decodeIfPresent(Double.self, forKey: .standHours)
        standHoursGoal = try container.decodeIfPresent(Double.self, forKey: .standHoursGoal)
        distanceWalkingRunningMeters = try container.decodeIfPresent(Double.self, forKey: .distanceWalkingRunningMeters)
        distanceWalkingRunningGoalMeters = try container.decodeIfPresent(Double.self, forKey: .distanceWalkingRunningGoalMeters)
        dateComponentsUTC = try container.decodeIfPresent(String.self, forKey: .dateComponentsUTC)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.wireType, forKey: .type)
        try container.encodeIfPresent(activeEnergyBurnedKilocalories, forKey: .activeEnergyBurnedKilocalories)
        try container.encodeIfPresent(activeEnergyBurnedGoalKilocalories, forKey: .activeEnergyBurnedGoalKilocalories)
        try container.encodeIfPresent(exerciseTimeMinutes, forKey: .exerciseTimeMinutes)
        try container.encodeIfPresent(exerciseTimeGoalMinutes, forKey: .exerciseTimeGoalMinutes)
        try container.encodeIfPresent(standHours, forKey: .standHours)
        try container.encodeIfPresent(standHoursGoal, forKey: .standHoursGoal)
        try container.encodeIfPresent(distanceWalkingRunningMeters, forKey: .distanceWalkingRunningMeters)
        try container.encodeIfPresent(distanceWalkingRunningGoalMeters, forKey: .distanceWalkingRunningGoalMeters)
        try container.encodeIfPresent(dateComponentsUTC, forKey: .dateComponentsUTC)
    }
}

/// One chunk of a series (workout route, ECG voltage, heartbeat intervals).
///
/// A logical series is transported as multiple independent records, one per
/// chunk, each bounded in size: `points` carries at most
/// `SeriesLimits.pointsPerChunk` rows, each row exactly `channels.count`
/// values in a fixed order (typically starting with a time offset in
/// seconds from the record's `startDate`). Chunk identity is deterministic
/// — derived from `(seriesID, chunkIndex)` — so retries stay idempotent and
/// the receiver's cascade deletes chunks with their parent.
struct SeriesData: Codable, Equatable, Sendable {
    let seriesType: String
    let seriesID: UUID
    let parentID: UUID?
    let chunkIndex: Int
    let channels: [String]
    /// Each row has exactly `channels.count` finite values.
    let points: [[Double]]

    private enum CodingKeys: String, CodingKey {
        case type, seriesType, seriesID, parentID, chunkIndex, channels, points
    }

    static let wireType = RecordKind.series.rawValue

    init(
        seriesType: String,
        seriesID: UUID,
        parentID: UUID?,
        chunkIndex: Int,
        channels: [String],
        points: [[Double]]
    ) {
        self.seriesType = seriesType
        self.seriesID = seriesID
        self.parentID = parentID
        self.chunkIndex = chunkIndex
        self.channels = channels
        self.points = points
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .type) == Self.wireType else {
            throw QuantityData.typeMismatch(decoder)
        }
        seriesType = try container.decode(String.self, forKey: .seriesType)
        seriesID = try container.decode(UUID.self, forKey: .seriesID)
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
        chunkIndex = try container.decode(Int.self, forKey: .chunkIndex)
        channels = try container.decode([String].self, forKey: .channels)
        points = try container.decode([[Double]].self, forKey: .points)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.wireType, forKey: .type)
        try container.encode(seriesType, forKey: .seriesType)
        try container.encode(seriesID, forKey: .seriesID)
        try container.encodeIfPresent(parentID, forKey: .parentID)
        try container.encode(chunkIndex, forKey: .chunkIndex)
        try container.encode(channels, forKey: .channels)
        try container.encode(points, forKey: .points)
    }
}

/// An electrocardiogram's structured facts. The voltage measurements travel
/// separately as `series` chunks (`seriesType` "electrocardiogramVoltage")
/// referencing this record through `parentID`/`seriesID`.
struct ElectrocardiogramData: Codable, Equatable, Sendable {
    let classification: String
    let classificationRawValue: Int?
    let symptomStatus: String?
    let symptomStatusRawValue: Int?
    /// count/min.
    let averageHeartRate: Double?
    /// Hz.
    let samplingFrequency: Double?
    let voltageSeriesID: UUID?
    let voltageChunkCount: Int?

    private enum CodingKeys: String, CodingKey {
        case type, classification, classificationRawValue
        case symptomStatus, symptomStatusRawValue
        case averageHeartRate, samplingFrequency
        case voltageSeriesID, voltageChunkCount
    }

    static let wireType = RecordKind.electrocardiogram.rawValue

    init(
        classification: String,
        classificationRawValue: Int?,
        symptomStatus: String?,
        symptomStatusRawValue: Int?,
        averageHeartRate: Double?,
        samplingFrequency: Double?,
        voltageSeriesID: UUID?,
        voltageChunkCount: Int?
    ) {
        self.classification = classification
        self.classificationRawValue = classificationRawValue
        self.symptomStatus = symptomStatus
        self.symptomStatusRawValue = symptomStatusRawValue
        self.averageHeartRate = averageHeartRate
        self.samplingFrequency = samplingFrequency
        self.voltageSeriesID = voltageSeriesID
        self.voltageChunkCount = voltageChunkCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .type) == Self.wireType else {
            throw QuantityData.typeMismatch(decoder)
        }
        classification = try container.decode(String.self, forKey: .classification)
        classificationRawValue = try container.decodeIfPresent(Int.self, forKey: .classificationRawValue)
        symptomStatus = try container.decodeIfPresent(String.self, forKey: .symptomStatus)
        symptomStatusRawValue = try container.decodeIfPresent(Int.self, forKey: .symptomStatusRawValue)
        averageHeartRate = try container.decodeIfPresent(Double.self, forKey: .averageHeartRate)
        samplingFrequency = try container.decodeIfPresent(Double.self, forKey: .samplingFrequency)
        voltageSeriesID = try container.decodeIfPresent(UUID.self, forKey: .voltageSeriesID)
        voltageChunkCount = try container.decodeIfPresent(Int.self, forKey: .voltageChunkCount)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.wireType, forKey: .type)
        try container.encode(classification, forKey: .classification)
        try container.encodeIfPresent(classificationRawValue, forKey: .classificationRawValue)
        try container.encodeIfPresent(symptomStatus, forKey: .symptomStatus)
        try container.encodeIfPresent(symptomStatusRawValue, forKey: .symptomStatusRawValue)
        try container.encodeIfPresent(averageHeartRate, forKey: .averageHeartRate)
        try container.encodeIfPresent(samplingFrequency, forKey: .samplingFrequency)
        try container.encodeIfPresent(voltageSeriesID, forKey: .voltageSeriesID)
        try container.encodeIfPresent(voltageChunkCount, forKey: .voltageChunkCount)
    }
}

/// A clinical record whose FHIR resource is preserved structurally.
struct ClinicalData: Codable, Equatable, Sendable {
    /// The FHIR resource type, e.g. "Condition".
    let fhirType: String
    let fhirIdentifier: String?
    let fhirResource: FHIRJSON

    private enum CodingKeys: String, CodingKey {
        case type, fhirType, fhirIdentifier, fhirResource
    }

    static let wireType = RecordKind.clinical.rawValue

    init(fhirType: String, fhirIdentifier: String?, fhirResource: FHIRJSON) {
        self.fhirType = fhirType
        self.fhirIdentifier = fhirIdentifier
        self.fhirResource = fhirResource
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .type) == Self.wireType else {
            throw QuantityData.typeMismatch(decoder)
        }
        fhirType = try container.decode(String.self, forKey: .fhirType)
        fhirIdentifier = try container.decodeIfPresent(String.self, forKey: .fhirIdentifier)
        fhirResource = try container.decode(FHIRJSON.self, forKey: .fhirResource)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.wireType, forKey: .type)
        try container.encode(fhirType, forKey: .fhirType)
        try container.encodeIfPresent(fhirIdentifier, forKey: .fhirIdentifier)
        try container.encode(fhirResource, forKey: .fhirResource)
    }
}

/// The typed content of a record. Encoding is a single JSON object whose
/// `type` discriminator equals the record's `kind`; decoding rejects an
/// unknown or mismatched type outright.
enum RecordData: Equatable, Sendable {
    case quantity(QuantityData)
    case category(CategoryData)
    case correlation(CorrelationData)
    case workout(WorkoutData)
    case activitySummary(ActivitySummaryData)
    case series(SeriesData)
    case electrocardiogram(ElectrocardiogramData)
    case clinical(ClinicalData)

    var kind: RecordKind {
        switch self {
        case .quantity: .quantity
        case .category: .category
        case .correlation: .correlation
        case .workout: .workout
        case .activitySummary: .activitySummary
        case .series: .series
        case .electrocardiogram: .electrocardiogram
        case .clinical: .clinical
        }
    }
}

extension RecordData: Codable {
    private enum TypeKey: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TypeKey.self)
        switch try container.decode(String.self, forKey: .type) {
        case QuantityData.wireType:
            self = .quantity(try QuantityData(from: decoder))
        case CategoryData.wireType:
            self = .category(try CategoryData(from: decoder))
        case CorrelationData.wireType:
            self = .correlation(try CorrelationData(from: decoder))
        case WorkoutData.wireType:
            self = .workout(try WorkoutData(from: decoder))
        case ActivitySummaryData.wireType:
            self = .activitySummary(try ActivitySummaryData(from: decoder))
        case SeriesData.wireType:
            self = .series(try SeriesData(from: decoder))
        case ElectrocardiogramData.wireType:
            self = .electrocardiogram(try ElectrocardiogramData(from: decoder))
        case ClinicalData.wireType:
            self = .clinical(try ClinicalData(from: decoder))
        case let other:
            // Unknown future record types must fail loudly until this app
            // understands their structural contract.
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown record data type \(other)."
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .quantity(let payload): try container.encode(payload)
        case .category(let payload): try container.encode(payload)
        case .correlation(let payload): try container.encode(payload)
        case .workout(let payload): try container.encode(payload)
        case .activitySummary(let payload): try container.encode(payload)
        case .series(let payload): try container.encode(payload)
        case .electrocardiogram(let payload): try container.encode(payload)
        case .clinical(let payload): try container.encode(payload)
        }
    }
}
