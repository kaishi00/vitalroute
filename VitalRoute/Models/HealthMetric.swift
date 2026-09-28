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

    /// For catalog construction in this file only; the compiler enforces
    /// that: every other caller must use the checked initializer (or
    /// decoding, which rejects unknown metrics instead of carrying them).
    fileprivate init(unchecked rawValue: String) {
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

/// Ergonomic constants for the current catalog. New metrics need no
/// addition here — `HealthMetric(rawValue:)` and the descriptor cover them.
extension HealthMetric {
    static let steps = HealthMetric(unchecked: "steps")
    static let heartRate = HealthMetric(unchecked: "heartRate")
    static let restingHeartRate = HealthMetric(unchecked: "restingHeartRate")
    static let heartRateVariability = HealthMetric(unchecked: "heartRateVariability")
    static let sleep = HealthMetric(unchecked: "sleep")
    static let activeEnergy = HealthMetric(unchecked: "activeEnergy")
    static let workouts = HealthMetric(unchecked: "workouts")
    static let bloodPressure = HealthMetric(unchecked: "bloodPressure")
    static let bloodPressureSystolic = HealthMetric(unchecked: "bloodPressureSystolic")
    static let bloodPressureDiastolic = HealthMetric(unchecked: "bloodPressureDiastolic")
}

/// What an ordinary quantity/category conversion looks like. Closed and
/// static: a new conversion joins this enum and the mapper's single switch
/// over it, rather than growing switches across the app.
enum CanonicalUnit: String, Hashable, Sendable {
    case count
    case countPerMinute
    case milliseconds
    case kilocalories
    case millimetersOfMercury
    case percent
    case kilograms
    case meters
    case metersPerSecond
    case degreesCelsius
    case milligramsPerDeciliter
    case millilitersPerKilogramMinute
    case watts
    case decibelsAWeightedSPL
    case minutes
}

/// How a category sample's raw value becomes a stable value name.
enum CategoryNaming: String, Hashable, Sendable {
    case sleepAnalysis
    case appleStandHour
    case mindfulSession
    case heartRateEvent
    case irregularHeartRhythmEvent
    case appleWalkingSteadinessEvent
    case environmentalAudioExposureEvent
    case headphoneAudioExposureEvent
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
        case activity
        case heart
        case vitals
        case mobility
        case body
        case sleep
        case hearing
        case mindfulness
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
    private static func quantity(_ raw: String, _ name: String, _ detail: String, _ symbol: String, _ group: MetricDescriptor.Group, _ identifier: String, _ unit: CanonicalUnit) -> MetricDescriptor {
        MetricDescriptor(metric: HealthMetric(unchecked: raw), displayName: name, shortDescription: detail, symbolName: symbol, group: group, healthKitIdentifier: identifier, extraction: .quantity(canonicalUnit: unit))
    }

    private static func category(_ raw: String, _ name: String, _ detail: String, _ symbol: String, _ group: MetricDescriptor.Group, _ identifier: String, _ naming: CategoryNaming) -> MetricDescriptor {
        MetricDescriptor(metric: HealthMetric(unchecked: raw), displayName: name, shortDescription: detail, symbolName: symbol, group: group, healthKitIdentifier: identifier, extraction: .category(naming: naming))
    }

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
            group: .heart,
            healthKitIdentifier: "HKQuantityTypeIdentifierHeartRate",
            extraction: .quantity(canonicalUnit: .countPerMinute)
        ),
        MetricDescriptor(
            metric: HealthMetric(unchecked: "restingHeartRate"),
            displayName: "Resting heart rate",
            shortDescription: "Resting heart rate samples",
            symbolName: "heart",
            group: .heart,
            healthKitIdentifier: "HKQuantityTypeIdentifierRestingHeartRate",
            extraction: .quantity(canonicalUnit: .countPerMinute)
        ),
        MetricDescriptor(
            metric: HealthMetric(unchecked: "heartRateVariability"),
            displayName: "Heart rate variability",
            shortDescription: "SDNN measurements",
            symbolName: "waveform.path.ecg",
            group: .heart,
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
        quantity("walkingHeartRateAverage", "Walking heart rate average", "Average heart rate while walking", "figure.walk", .heart, "HKQuantityTypeIdentifierWalkingHeartRateAverage", .countPerMinute),
        quantity("heartRateRecoveryOneMinute", "Heart rate recovery", "Heart rate decrease after one minute", "heart", .heart, "HKQuantityTypeIdentifierHeartRateRecoveryOneMinute", .countPerMinute),
        quantity("vo2Max", "VO₂ max", "Cardiorespiratory fitness estimate", "lungs", .heart, "HKQuantityTypeIdentifierVO2Max", .millilitersPerKilogramMinute),
        quantity("atrialFibrillationBurden", "Atrial fibrillation burden", "Time in atrial fibrillation", "waveform.path.ecg", .heart, "HKQuantityTypeIdentifierAtrialFibrillationBurden", .percent),
        quantity("oxygenSaturation", "Oxygen saturation", "Blood oxygen saturation", "lungs", .vitals, "HKQuantityTypeIdentifierOxygenSaturation", .percent),
        quantity("respiratoryRate", "Respiratory rate", "Breaths per minute", "wind", .vitals, "HKQuantityTypeIdentifierRespiratoryRate", .countPerMinute),
        quantity("bodyTemperature", "Body temperature", "Body temperature measurement", "thermometer.medium", .vitals, "HKQuantityTypeIdentifierBodyTemperature", .degreesCelsius),
        quantity("bloodGlucose", "Blood glucose", "Blood glucose concentration", "drop", .vitals, "HKQuantityTypeIdentifierBloodGlucose", .milligramsPerDeciliter),
        quantity("appleSleepingWristTemperature", "Wrist temperature", "Temperature while sleeping", "thermometer.medium", .sleep, "HKQuantityTypeIdentifierAppleSleepingWristTemperature", .degreesCelsius),
        quantity("bodyMass", "Body mass", "Body weight measurement", "scalemass", .body, "HKQuantityTypeIdentifierBodyMass", .kilograms),
        quantity("bodyFatPercentage", "Body fat percentage", "Proportion of body mass that is fat", "percent", .body, "HKQuantityTypeIdentifierBodyFatPercentage", .percent),
        quantity("leanBodyMass", "Lean body mass", "Body mass excluding fat", "figure.stand", .body, "HKQuantityTypeIdentifierLeanBodyMass", .kilograms),
        quantity("bodyMassIndex", "Body mass index", "Body mass index measurement", "figure.stand", .body, "HKQuantityTypeIdentifierBodyMassIndex", .count),
        quantity("height", "Height", "Height measurement", "ruler", .body, "HKQuantityTypeIdentifierHeight", .meters),
        quantity("waistCircumference", "Waist circumference", "Waist circumference measurement", "ruler", .body, "HKQuantityTypeIdentifierWaistCircumference", .meters),
        quantity("flightsClimbed", "Flights climbed", "Flights of stairs climbed", "stairs", .activity, "HKQuantityTypeIdentifierFlightsClimbed", .count),
        quantity("distanceWalkingRunning", "Walking and running distance", "Distance walked or run", "figure.walk", .activity, "HKQuantityTypeIdentifierDistanceWalkingRunning", .meters),
        quantity("distanceCycling", "Cycling distance", "Distance cycled", "bicycle", .activity, "HKQuantityTypeIdentifierDistanceCycling", .meters),
        quantity("distanceSwimming", "Swimming distance", "Distance swum", "figure.pool.swim", .activity, "HKQuantityTypeIdentifierDistanceSwimming", .meters),
        quantity("appleExerciseTime", "Exercise time", "Minutes spent exercising", "figure.run", .activity, "HKQuantityTypeIdentifierAppleExerciseTime", .minutes),
        quantity("appleStandTime", "Stand time", "Minutes spent standing", "figure.stand", .activity, "HKQuantityTypeIdentifierAppleStandTime", .minutes),
        quantity("basalEnergyBurned", "Basal energy", "Energy used at rest", "flame", .activity, "HKQuantityTypeIdentifierBasalEnergyBurned", .kilocalories),
        quantity("runningPower", "Running power", "Power while running", "figure.run", .activity, "HKQuantityTypeIdentifierRunningPower", .watts),
        quantity("runningSpeed", "Running speed", "Speed while running", "figure.run", .activity, "HKQuantityTypeIdentifierRunningSpeed", .metersPerSecond),
        quantity("cyclingPower", "Cycling power", "Power while cycling", "bicycle", .activity, "HKQuantityTypeIdentifierCyclingPower", .watts),
        quantity("cyclingSpeed", "Cycling speed", "Speed while cycling", "bicycle", .activity, "HKQuantityTypeIdentifierCyclingSpeed", .metersPerSecond),
        quantity("cyclingCadence", "Cycling cadence", "Pedal revolutions per minute", "bicycle", .activity, "HKQuantityTypeIdentifierCyclingCadence", .countPerMinute),
        quantity("distanceWheelchair", "Wheelchair distance", "Distance traveled in a wheelchair", "figure.roll", .activity, "HKQuantityTypeIdentifierDistanceWheelchair", .meters),
        quantity("pushCount", "Wheelchair pushes", "Wheelchair push count", "figure.roll", .activity, "HKQuantityTypeIdentifierPushCount", .count),
        quantity("walkingSpeed", "Walking speed", "Walking speed measurement", "figure.walk", .mobility, "HKQuantityTypeIdentifierWalkingSpeed", .metersPerSecond),
        quantity("walkingStepLength", "Walking step length", "Length of walking steps", "figure.walk", .mobility, "HKQuantityTypeIdentifierWalkingStepLength", .meters),
        quantity("walkingAsymmetryPercentage", "Walking asymmetry", "Percentage of asymmetric steps", "figure.walk", .mobility, "HKQuantityTypeIdentifierWalkingAsymmetryPercentage", .percent),
        quantity("walkingDoubleSupportPercentage", "Walking double support", "Percentage of gait cycle with both feet down", "figure.walk", .mobility, "HKQuantityTypeIdentifierWalkingDoubleSupportPercentage", .percent),
        quantity("stairAscentSpeed", "Stair ascent speed", "Speed ascending stairs", "figure.stairs", .mobility, "HKQuantityTypeIdentifierStairAscentSpeed", .metersPerSecond),
        quantity("stairDescentSpeed", "Stair descent speed", "Speed descending stairs", "figure.stairs", .mobility, "HKQuantityTypeIdentifierStairDescentSpeed", .metersPerSecond),
        quantity("sixMinuteWalkTestDistance", "Six-minute walk distance", "Distance in a six-minute walk test", "figure.walk", .mobility, "HKQuantityTypeIdentifierSixMinuteWalkTestDistance", .meters),
        quantity("appleWalkingSteadiness", "Walking steadiness", "Walking steadiness estimate", "figure.walk", .mobility, "HKQuantityTypeIdentifierAppleWalkingSteadiness", .percent),
        quantity("environmentalAudioExposure", "Environmental audio exposure", "Environmental sound level", "ear", .hearing, "HKQuantityTypeIdentifierEnvironmentalAudioExposure", .decibelsAWeightedSPL),
        quantity("headphoneAudioExposure", "Headphone audio exposure", "Headphone sound level", "headphones", .hearing, "HKQuantityTypeIdentifierHeadphoneAudioExposure", .decibelsAWeightedSPL),
        category("appleStandHour", "Stand hour", "Hourly stand goal status", "figure.stand", .activity, "HKCategoryTypeIdentifierAppleStandHour", .appleStandHour),
        category("mindfulSession", "Mindful session", "Mindfulness session intervals", "brain.head.profile", .mindfulness, "HKCategoryTypeIdentifierMindfulSession", .mindfulSession),
        category("highHeartRateEvent", "High heart rate event", "High heart rate notifications", "heart", .heart, "HKCategoryTypeIdentifierHighHeartRateEvent", .heartRateEvent),
        category("lowHeartRateEvent", "Low heart rate event", "Low heart rate notifications", "heart", .heart, "HKCategoryTypeIdentifierLowHeartRateEvent", .heartRateEvent),
        category("irregularHeartRhythmEvent", "Irregular rhythm event", "Irregular heart rhythm notifications", "waveform.path.ecg", .heart, "HKCategoryTypeIdentifierIrregularHeartRhythmEvent", .irregularHeartRhythmEvent),
        category("appleWalkingSteadinessEvent", "Walking steadiness event", "Walking steadiness notifications", "figure.walk", .mobility, "HKCategoryTypeIdentifierAppleWalkingSteadinessEvent", .appleWalkingSteadinessEvent),
        // The current HealthKit case retains its pre-rename raw identifier.
        category("environmentalAudioExposureEvent", "Environmental audio event", "Environmental sound exposure events", "ear", .hearing, "HKCategoryTypeIdentifierAudioExposureEvent", .environmentalAudioExposureEvent),
        category("headphoneAudioExposureEvent", "Headphone audio event", "Headphone sound exposure events", "headphones", .hearing, "HKCategoryTypeIdentifierHeadphoneAudioExposureEvent", .headphoneAudioExposureEvent),
        // Correlation plumbing: blood pressure's components are real
        // quantity metrics referenced by correlation records, but they are
        // never selected or exported on their own (userSelectable: false).
        MetricDescriptor(
            metric: HealthMetric(unchecked: "bloodPressureSystolic"),
            displayName: "Blood pressure (systolic)",
            shortDescription: "Systolic component of blood pressure correlations",
            symbolName: "stethoscope",
            group: .vitals,
            healthKitIdentifier: "HKQuantityTypeIdentifierBloodPressureSystolic",
            extraction: .quantity(canonicalUnit: .millimetersOfMercury),
            userSelectable: false
        ),
        MetricDescriptor(
            metric: HealthMetric(unchecked: "bloodPressureDiastolic"),
            displayName: "Blood pressure (diastolic)",
            shortDescription: "Diastolic component of blood pressure correlations",
            symbolName: "stethoscope",
            group: .vitals,
            healthKitIdentifier: "HKQuantityTypeIdentifierBloodPressureDiastolic",
            extraction: .quantity(canonicalUnit: .millimetersOfMercury),
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
            userSelectable: true
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
