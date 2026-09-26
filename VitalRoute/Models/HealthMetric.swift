import Foundation

/// The app-facing identity of one HealthKit metric, backed by a stable
/// string identifier (the wire and persistence spelling). Unlike a plain
/// string, only identifiers present in `MetricCatalog` can be constructed,
/// so decoding or selecting an unknown metric fails loudly at the edge.
struct HealthMetric: Hashable, Codable, Identifiable, Sendable, Comparable {
    let rawValue: String

    var id: String { rawValue }

    var descriptor: MetricDescriptor {
        // Every instance is minted through the catalog-checked
        // initializers, so the lookup cannot legitimately fail.
        guard let descriptor = MetricCatalog.descriptor(for: self) else {
            preconditionFailure("HealthMetric \(rawValue) is not in the catalog")
        }
        return descriptor
    }

    // Catalog passthroughs: UI reads these straight off the metric.
    var displayName: String { descriptor.displayName }
    var shortDescription: String { descriptor.shortDescription }
    var symbolName: String { descriptor.symbolName }
    var group: MetricDescriptor.Group { descriptor.group }

    /// Catalog-checked construction. Returns nil for identifiers the
    /// catalog does not define.
    init?(rawValue: String) {
        guard MetricCatalog.contains(rawValue: rawValue) else { return nil }
        self.rawValue = rawValue
    }

    /// For catalog construction and decoding only. Callers outside
    /// `MetricCatalog` must use the checked initializer; decoding uses it
    /// so persisted selections and checkpoints of unknown metrics are
    /// rejected instead of silently carried.
    init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard MetricCatalog.contains(rawValue: raw) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown health metric \(raw)."
            ))
        }
        self.rawValue = raw
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func < (lhs: HealthMetric, rhs: HealthMetric) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// What an ordinary quantity/category conversion looks like. Closed and
/// static: a new conversion joins this enum and the mapper's single switch
/// over it, rather than growing switches across the app.
enum CanonicalUnit: String, Hashable, Sendable {
    case count
    case countPerMinute
    case milliseconds
    case kilocalories
}

/// How a category sample's raw value becomes a stable value name.
enum CategoryNaming: String, Hashable, Sendable {
    case sleepAnalysis
}

/// How a metric's HealthKit samples become records. The mapper switches on
/// this plan; ordinary metrics never add mapper code.
enum ExtractionPlan: Hashable, Sendable {
    case quantity(canonicalUnit: CanonicalUnit)
    case category(naming: CategoryNaming)
    case correlation
    case workout
    case electrocardiogram
    case clinical

    var recordKind: RecordKind {
        switch self {
        case .quantity: .quantity
        case .category: .category
        case .correlation: .correlation
        case .workout: .workout
        case .electrocardiogram: .electrocardiogram
        case .clinical: .clinical
        }
    }
}

/// One catalog entry: everything the app knows about a metric, in one
/// value. Adding an ordinary metric means adding one descriptor to
/// `MetricCatalog.metrics` — no other switch in the app changes.
struct MetricDescriptor: Hashable, Identifiable, Sendable {
    /// UI grouping for the Health Data screen.
    enum Group: String, CaseIterable, Sendable {
        case vitals
        case sleep
        case activity
    }

    let metric: HealthMetric
    var id: String { metric.id }

    let displayName: String
    let shortDescription: String
    let symbolName: String
    let group: Group

    /// The HealthKit object type identifier, e.g.
    /// "HKQuantityTypeIdentifierStepCount". The mapper resolves it to a
    /// live HKSampleType.
    let healthKitIdentifier: String

    /// How samples of this metric become records.
    let extraction: ExtractionPlan

    /// Component metrics a correlation sample carries, by HealthKit
    /// identifier. These must also be authorized to read the correlation.
    let componentIdentifiers: [String]

    /// False for metrics that exist to describe parts of other records
    /// (e.g. the components of a blood pressure correlation). Invisible to
    /// selection and never exported on their own.
    let userSelectable: Bool

    init(
        metric: HealthMetric,
        displayName: String,
        shortDescription: String,
        symbolName: String,
        group: Group,
        healthKitIdentifier: String,
        extraction: ExtractionPlan,
        componentIdentifiers: [String] = [],
        userSelectable: Bool = true
    ) {
        self.metric = metric
        self.displayName = displayName
        self.shortDescription = shortDescription
        self.symbolName = symbolName
        self.group = group
        self.healthKitIdentifier = healthKitIdentifier
        self.extraction = extraction
        self.componentIdentifiers = componentIdentifiers
        self.userSelectable = userSelectable
    }

    var recordKind: RecordKind {
        extraction.recordKind
    }
}

/// The metric catalog: the single, statically-checked list of metrics this
/// app can represent. The iOS client owns this catalog — the receiver
/// deliberately does not duplicate it.
enum MetricCatalog {
    static let metrics: [MetricDescriptor] = [
        MetricDescriptor(
            metric: HealthMetric(unchecked: "steps"),
            displayName: "Steps",
            shortDescription: "Daily movement",
            symbolName: "figure.walk",
            group: .activity,
            healthKitIdentifier: "HKQuantityTypeIdentifierStepCount",
            extraction: .quantity(canonicalUnit: .count)
        ),
        MetricDescriptor(
            metric: HealthMetric(unchecked: "heartRate"),
            displayName: "Heart rate",
            shortDescription: "Heart rate samples",
            symbolName: "heart",
            group: .vitals,
            healthKitIdentifier: "HKQuantityTypeIdentifierHeartRate",
            extraction: .quantity(canonicalUnit: .countPerMinute)
        ),
        MetricDescriptor(
            metric: HealthMetric(unchecked: "restingHeartRate"),
            displayName: "Resting heart rate",
            shortDescription: "Resting heart rate samples",
            symbolName: "heart",
            group: .vitals,
            healthKitIdentifier: "HKQuantityTypeIdentifierRestingHeartRate",
            extraction: .quantity(canonicalUnit: .countPerMinute)
        ),
        MetricDescriptor(
            metric: HealthMetric(unchecked: "heartRateVariability"),
            displayName: "Heart rate variability",
            shortDescription: "SDNN measurements",
            symbolName: "waveform.path.ecg",
            group: .vitals,
            healthKitIdentifier: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
            extraction: .quantity(canonicalUnit: .milliseconds)
        ),
        MetricDescriptor(
            metric: HealthMetric(unchecked: "sleep"),
            displayName: "Sleep",
            shortDescription: "Sleep stages and intervals",
            symbolName: "bed.double",
            group: .sleep,
            healthKitIdentifier: "HKCategoryTypeIdentifierSleepAnalysis",
            extraction: .category(naming: .sleepAnalysis)
        ),
        MetricDescriptor(
            metric: HealthMetric(unchecked: "activeEnergy"),
            displayName: "Active energy",
            shortDescription: "Energy burned during activity",
            symbolName: "flame",
            group: .activity,
            healthKitIdentifier: "HKQuantityTypeIdentifierActiveEnergyBurned",
            extraction: .quantity(canonicalUnit: .kilocalories)
        ),
        MetricDescriptor(
            metric: HealthMetric(unchecked: "workouts"),
            displayName: "Workouts",
            shortDescription: "Workout intervals and details",
            symbolName: "figure.run",
            group: .activity,
            healthKitIdentifier: "HKWorkoutTypeIdentifier",
            extraction: .workout
        ),
        // Correlation plumbing: blood pressure's components are real
        // quantity metrics referenced by correlation records, but they are
        // never selected or exported on their own (userSelectable: false).
        // A visible bloodPressure metric is future catalog work; the record
        // shape and mapper already carry it.
        MetricDescriptor(
            metric: HealthMetric(unchecked: "bloodPressureSystolic"),
            displayName: "Blood pressure (systolic)",
            shortDescription: "Systolic component of blood pressure correlations",
            symbolName: "stethoscope",
            group: .vitals,
            healthKitIdentifier: "HKQuantityTypeIdentifierBloodPressureSystolic",
            extraction: .quantity(canonicalUnit: .countPerMinute),
            userSelectable: false
        ),
        MetricDescriptor(
            metric: HealthMetric(unchecked: "bloodPressureDiastolic"),
            displayName: "Blood pressure (diastolic)",
            shortDescription: "Diastolic component of blood pressure correlations",
            symbolName: "stethoscope",
            group: .vitals,
            healthKitIdentifier: "HKQuantityTypeIdentifierBloodPressureDiastolic",
            extraction: .quantity(canonicalUnit: .countPerMinute),
            userSelectable: false
        ),
        MetricDescriptor(
            metric: HealthMetric(unchecked: "bloodPressure"),
            displayName: "Blood pressure",
            shortDescription: "Blood pressure correlations",
            symbolName: "stethoscope",
            group: .vitals,
            healthKitIdentifier: "HKCorrelationTypeIdentifierBloodPressure",
            extraction: .correlation,
            componentIdentifiers: [
                "HKQuantityTypeIdentifierBloodPressureSystolic",
                "HKQuantityTypeIdentifierBloodPressureDiastolic",
            ],
            userSelectable: false
        ),
    ]

    static func descriptor(for metric: HealthMetric) -> MetricDescriptor? {
        descriptorsByRawValue[metric.rawValue]
    }

    static func contains(rawValue: String) -> Bool {
        descriptorsByRawValue[rawValue] != nil
    }

    /// Reverse lookup: the catalog metric for a HealthKit type identifier.
    /// Used by correlation extraction to attribute component samples.
    static func metric(withHealthKitIdentifier identifier: String) -> HealthMetric? {
        metrics.first { $0.healthKitIdentifier == identifier }?.metric
    }

    /// The descriptors a user can select for export, in catalog order.
    static var selectableMetrics: [MetricDescriptor] {
        metrics.filter { $0.userSelectable }
    }

    private static let descriptorsByRawValue: [String: MetricDescriptor] = {
        var map: [String: MetricDescriptor] = [:]
        for descriptor in metrics {
            let existing = map[descriptor.metric.rawValue]
            precondition(
                existing == nil,
                "MetricCatalog defines \(descriptor.metric.rawValue) more than once"
            )
            map[descriptor.metric.rawValue] = descriptor
        }
        return map
    }()
}
