import Foundation
import HealthKit
import CryptoKit

/// One HealthKit sample mapped by the extractor. `record` is the sample's
/// own record (nil for samples that are purely series heads);
/// `seriesRequest` asks the series loader to fetch chunk records for
/// samples whose data continues in a series (ECG voltage today, workout
/// routes when a catalog metric exposes them).
struct MappedSample: Equatable, Sendable {
    let record: HealthRecord?
    let seriesRequest: SeriesRequest?

    init(record: HealthRecord? = nil, seriesRequest: SeriesRequest? = nil) {
        self.record = record
        self.seriesRequest = seriesRequest
    }
}

/// One pending series fetch for a parent sample.
struct SeriesRequest: Equatable, Sendable {
    /// The HealthKit series object's UUID (route/ECG).
    let seriesID: UUID
    let parentID: UUID
    let parentStart: Date
    let parentEnd: Date
}

/// Converts HealthKit objects into typed records.
///
/// Extraction is driven by each metric's `ExtractionPlan`, so adding an
/// ordinary quantity or category metric is catalog work only. The
/// structural extractors below (quantity conversion, category naming,
/// correlation component attribution, workout details, ECG facts, clinical
/// FHIR, series chunking) are shared by every metric of that kind.
enum HealthKitRecordMapper {
    // MARK: - Types and authorization

    /// The sample type backing a descriptor, resolved from its HealthKit
    /// identifier. Nil when the type does not exist on this OS version.
    static func sampleType(for descriptor: MetricDescriptor) -> HKSampleType? {
        Self.sampleType(healthKitIdentifier: descriptor.healthKitIdentifier)
    }

    static func sampleType(healthKitIdentifier: String) -> HKSampleType? {
        // The HealthKit identifier enums spell their raw values with the
        // full prefix ("HKQuantityTypeIdentifierStepCount"), matching the
        // catalog strings; a family mismatch resolves to nil and falls
        // through to the next family.
        let quantity = HKQuantityTypeIdentifier(rawValue: healthKitIdentifier)
        if let type = HKObjectType.quantityType(forIdentifier: quantity) {
            return type
        }
        let category = HKCategoryTypeIdentifier(rawValue: healthKitIdentifier)
        if let type = HKObjectType.categoryType(forIdentifier: category) {
            return type
        }
        let correlation = HKCorrelationTypeIdentifier(rawValue: healthKitIdentifier)
        if let type = HKObjectType.correlationType(forIdentifier: correlation) {
            return type
        }
        let clinical = HKClinicalTypeIdentifier(rawValue: healthKitIdentifier)
        if let type = HKObjectType.clinicalType(forIdentifier: clinical) {
            return type
        }
        switch healthKitIdentifier {
        case "HKWorkoutTypeIdentifier":
            return HKObjectType.workoutType()
        case "HKElectrocardiogramType":
            return HKObjectType.electrocardiogramType()
        default:
            return nil
        }
    }

    /// Every object type that must be authorized to read the given
    /// metrics: each metric's own type plus the component types of
    /// correlations (a blood pressure correlation is unreadable without
    /// its systolic/diastolic quantity types).
    static func objectTypes(for metrics: Set<HealthMetric>) -> Set<HKObjectType> {
        var types = Set<HKObjectType>()
        for metric in metrics {
            let descriptor = metric.descriptor
            let identifiers = [descriptor.healthKitIdentifier] + descriptor.componentIdentifiers
            for identifier in identifiers {
                if let type = Self.sampleType(healthKitIdentifier: identifier) {
                    types.insert(type)
                }
            }
        }
        return types
    }

    /// Sample types for observers and queries: one per metric, deduplicated.
    static func sampleTypes(for metrics: Set<HealthMetric>) -> [HKSampleType] {
        var seen = Set<String>()
        var types: [HKSampleType] = []
        for metric in MetricCatalog.metrics.map(\.metric) where metrics.contains(metric) {
            guard let type = sampleType(for: metric.descriptor) else { continue }
            if seen.insert(type.identifier).inserted {
                types.append(type)
            }
        }
        return types
    }

    // MARK: - Sample mapping

    /// Maps one sample according to its metric's extraction plan. Runs on
    /// the HealthKit callback thread; only Sendable values leave.
    static func makeMappedSample(from sample: HKSample, metric: HealthMetric) -> MappedSample? {
        let envelope = Envelope(
            id: sample.uuid,
            metric: metric,
            startDate: sample.startDate,
            endDate: sample.endDate,
            sourceName: sample.sourceRevision.source.name,
            deviceName: sample.device?.name,
            metadata: sampleMetadata(sample)
        )
        switch metric.descriptor.extraction {
        case .quantity(let canonicalUnit):
            guard let quantity = sample as? HKQuantitySample else { return nil }
            return MappedSample(record: envelope.record(data: .quantity(QuantityData(
                value: quantity.quantity.doubleValue(for: canonicalUnit.hkUnit),
                unit: canonicalUnit.unitString
            ))))
        case .category(let naming):
            guard let category = sample as? HKCategorySample else { return nil }
            return MappedSample(record: envelope.record(data: .category(CategoryData(
                value: category.value,
                name: categoryName(category.value, naming: naming)
            ))))
        case .correlation:
            guard let correlation = sample as? HKCorrelation else { return nil }
            guard let data = correlationData(correlation) else { return nil }
            return MappedSample(record: envelope.record(data: .correlation(data)))
        case .workout:
            guard let workout = sample as? HKWorkout else { return nil }
            return MappedSample(record: envelope.record(data: .workout(workoutData(workout))))
        case .electrocardiogram:
            guard let ecg = sample as? HKElectrocardiogram else { return nil }
            return MappedSample(
                record: envelope.record(data: .electrocardiogram(electrocardiogramData(ecg))),
                seriesRequest: SeriesRequest(
                    seriesID: ecg.uuid,
                    parentID: ecg.uuid,
                    parentStart: ecg.startDate,
                    parentEnd: ecg.endDate
                )
            )
        case .clinical:
            guard let clinical = sample as? HKClinicalRecord else { return nil }
            guard let data = clinicalData(clinical) else { return nil }
            return MappedSample(record: envelope.record(data: .clinical(data)))
        }
    }

    private struct Envelope {
        let id: UUID
        let metric: HealthMetric
        let startDate: Date
        let endDate: Date
        let sourceName: String?
        let deviceName: String?
        let metadata: [String: String]

        func record(data: RecordData) -> HealthRecord {
            HealthRecord(
                id: id,
                metric: metric,
                startDate: startDate,
                endDate: endDate,
                sourceName: sourceName,
                deviceName: deviceName,
                metadata: metadata,
                data: data
            )
        }
    }

    /// HealthKit sample metadata, filtered to string values: the envelope's
    /// `metadata` is a string map, and HealthKit metadata values that are
    /// not strings (rare, binary flags) have no faithful string spelling.
    private static func sampleMetadata(_ sample: HKSample) -> [String: String] {
        var metadata: [String: String] = [:]
        for (key, value) in sample.metadata ?? [:] {
            if let value = value as? String {
                metadata[key] = value
            }
        }
        return metadata
    }

    // MARK: - Quantity units

    static func categoryName(_ rawValue: Int, naming: CategoryNaming) -> String? {
        switch naming {
        case .sleepAnalysis:
            sleepStageName(rawValue)
        }
    }

    private static func sleepStageName(_ rawValue: Int) -> String? {
        switch HKCategoryValueSleepAnalysis(rawValue: rawValue) {
        case .some(.inBed):
            "inBed"
        case .some(.asleepUnspecified):
            "asleepUnspecified"
        case .some(.awake):
            "awake"
        case .some(.asleepCore):
            "asleepCore"
        case .some(.asleepDeep):
            "asleepDeep"
        case .some(.asleepREM):
            "asleepREM"
        case .none:
            nil
        @unknown default:
            nil
        }
    }

    // MARK: - Correlation

    /// Attributes each contained quantity sample to its catalog metric.
    /// Components whose type is not in the catalog are skipped; a
    /// correlation with no attributable components maps to no record.
    static func correlationData(_ correlation: HKCorrelation) -> CorrelationData? {
        var components: [CorrelationComponent] = []
        for object in correlation.objects {
            guard let quantitySample = object as? HKQuantitySample else { continue }
            let typeIdentifier = quantitySample.quantityType.identifier
            guard let metric = MetricCatalog.metric(withHealthKitIdentifier: typeIdentifier),
                  case .quantity(let canonicalUnit) = metric.descriptor.extraction
            else { continue }
            components.append(CorrelationComponent(
                metric: metric.rawValue,
                value: quantitySample.quantity.doubleValue(for: canonicalUnit.hkUnit),
                unit: canonicalUnit.unitString
            ))
        }
        guard !components.isEmpty else { return nil }
        // HealthKit correlations carry their objects as a set; a stable
        // order keeps the encoded payload deterministic.
        return CorrelationData(components: components.sorted { $0.metric < $1.metric })
    }

    // MARK: - Workouts

    static func workoutData(_ workout: HKWorkout) -> WorkoutData {
        WorkoutData(
            activityType: activityTypeName(workout.workoutActivityType),
            activityTypeRawValue: Int(workout.workoutActivityType.rawValue),
            duration: workout.duration,
            totalEnergyKilocalories: workoutStatistics(workout, quantityTypeIdentifier: "HKQuantityTypeIdentifierActiveEnergyBurned")?
                .doubleValue(for: HKUnit.kilocalorie()),
            totalDistanceMeters: workoutDistance(statisticsByType: { workout.statistics(for: $0)?.sumQuantity() })?
                .doubleValue(for: .meter())
        )
    }

    private static func workoutStatistics(
        _ workout: HKWorkout,
        quantityTypeIdentifier: String
    ) -> HKQuantity? {
        guard let type = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: quantityTypeIdentifier)) else {
            return nil
        }
        return workout.statistics(for: type)?.sumQuantity()
    }

    /// Workouts record distance under activity-specific quantity types, and
    /// multisport workouts can carry several; summing all measured types
    /// matches the historical behavior. statistics(for:) returns nil for
    /// types a workout does not measure.
    private static let distanceTypes: [HKQuantityType] = [
        .distanceWalkingRunning,
        .distanceCycling,
        .distanceSwimming,
        .distanceWheelchair,
        .distanceDownhillSnowSports,
        .distanceCrossCountrySkiing,
        .distancePaddleSports,
        .distanceRowing,
        .distanceSkatingSports
    ].compactMap { HKObjectType.quantityType(forIdentifier: $0) }

    /// Sums the workout's measured distance statistics. Takes the statistics
    /// lookup as a closure so tests can exercise the selection logic without
    /// a live HKHealthStore.
    static func workoutDistance(statisticsByType: (HKQuantityType) -> HKQuantity?) -> HKQuantity? {
        var totalMeters = 0.0
        var foundAny = false
        for type in distanceTypes {
            if let quantity = statisticsByType(type) {
                totalMeters += quantity.doubleValue(for: .meter())
                foundAny = true
            }
        }
        return foundAny ? HKQuantity(unit: .meter(), doubleValue: totalMeters) : nil
    }

    /// Stable, non-localized activity names. Unlisted activity types fall
    /// back to a deterministic "hkActivityType<raw>" spelling; the raw
    /// value always travels alongside, so fidelity never depends on this
    /// list.
    static func activityTypeName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .americanFootball: "americanFootball"
        case .archery: "archery"
        case .australianFootball: "australianFootball"
        case .badminton: "badminton"
        case .baseball: "baseball"
        case .basketball: "basketball"
        case .bowling: "bowling"
        case .boxing: "boxing"
        case .climbing: "climbing"
        case .cricket: "cricket"
        case .crossTraining: "crossTraining"
        case .curling: "curling"
        case .cycling: "cycling"
        case .dance: "dance"
        case .danceInspiredTraining: "danceInspiredTraining"
        case .elliptical: "elliptical"
        case .equestrianSports: "equestrianSports"
        case .fencing: "fencing"
        case .fishing: "fishing"
        case .functionalStrengthTraining: "functionalStrengthTraining"
        case .golf: "golf"
        case .gymnastics: "gymnastics"
        case .handball: "handball"
        case .hiking: "hiking"
        case .hockey: "hockey"
        case .hunting: "hunting"
        case .lacrosse: "lacrosse"
        case .martialArts: "martialArts"
        case .mindAndBody: "mindAndBody"
        case .mixedCardio: "mixedCardio"
        case .paddleSports: "paddleSports"
        case .play: "play"
        case .preparationAndRecovery: "preparationAndRecovery"
        case .racquetball: "racquetball"
        case .rowing: "rowing"
        case .rugby: "rugby"
        case .running: "running"
        case .sailing: "sailing"
        case .skatingSports: "skatingSports"
        case .snowSports: "snowSports"
        case .soccer: "soccer"
        case .softball: "softball"
        case .squash: "squash"
        case .stairClimbing: "stairClimbing"
        case .stepTraining: "stepTraining"
        case .surfingSports: "surfingSports"
        case .swimming: "swimming"
        case .tableTennis: "tableTennis"
        case .taiChi: "taiChi"
        case .tennis: "tennis"
        case .trackAndField: "trackAndField"
        case .traditionalStrengthTraining: "traditionalStrengthTraining"
        case .volleyball: "volleyball"
        case .walking: "walking"
        case .waterFitness: "waterFitness"
        case .waterPolo: "waterPolo"
        case .waterSports: "waterSports"
        case .wrestling: "wrestling"
        case .yoga: "yoga"
        case .barre: "barre"
        case .coreTraining: "coreTraining"
        case .crossCountrySkiing: "crossCountrySkiing"
        case .downhillSkiing: "downhillSkiing"
        case .flexibility: "flexibility"
        case .highIntensityIntervalTraining: "highIntensityIntervalTraining"
        case .jumpRope: "jumpRope"
        case .kickboxing: "kickboxing"
        case .pilates: "pilates"
        case .snowboarding: "snowboarding"
        case .stairs: "stairs"
        case .wheelchairWalkPace: "wheelchairWalkPace"
        case .wheelchairRunPace: "wheelchairRunPace"
        @unknown default:
            "hkActivityType\(type.rawValue)"
        }
    }

    // MARK: - Electrocardiograms

    static func electrocardiogramData(_ ecg: HKElectrocardiogram) -> ElectrocardiogramData {
        ElectrocardiogramData(
            classification: ecgClassificationName(ecg.classification),
            classificationRawValue: ecg.classification.rawValue,
            symptomStatus: ecgSymptomStatusName(ecg.symptomsStatus),
            symptomStatusRawValue: ecg.symptomsStatus.rawValue,
            averageHeartRate: ecg.averageHeartRate?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
            samplingFrequency: ecg.samplingFrequency?.doubleValue(for: .hertz()),
            voltageSeriesID: ecg.uuid,
            voltageChunkCount: nil
        )
    }

    static func ecgClassificationName(_ classification: HKElectrocardiogram.Classification) -> String {
        switch classification {
        case .notSet: "notSet"
        case .sinusRhythm: "sinusRhythm"
        case .atrialFibrillation: "atrialFibrillation"
        case .inconclusiveLowHeartRate: "inconclusiveLowHeartRate"
        case .inconclusiveHighHeartRate: "inconclusiveHighHeartRate"
        case .inconclusivePoorReading: "inconclusivePoorReading"
        case .inconclusiveOther: "inconclusiveOther"
        @unknown default:
            "hkECGClassification\(classification.rawValue)"
        }
    }

    /// HealthKit spells this "SymptomsStatus" and never leaves it unset
    /// optionals: notSet/none/present are the documented values.
    static func ecgSymptomStatusName(_ status: HKElectrocardiogram.SymptomsStatus) -> String? {
        switch status {
        case .notSet: "notSet"
        case .none: "none"
        case .present: "present"
        @unknown default:
            nil
        }
    }

    // MARK: - Clinical records

    /// Decodes the FHIR resource payload structurally. A record without a
    /// readable resource maps to no record rather than a degraded one.
    static func clinicalData(_ record: HKClinicalRecord) -> ClinicalData? {
        guard let resource = record.fhirResource else { return nil }
        guard let value = try? JSONDecoder().decode(FHIRJSON.self, from: resource.data),
              case .object = value
        else { return nil }
        return ClinicalData(
            fhirType: resource.resourceType.rawValue,
            fhirIdentifier: resource.identifier.isEmpty ? nil : resource.identifier,
            fhirResource: value
        )
    }

    // MARK: - Series chunking

    /// Series transport bounds. A chunk record's canonical JSON stays far
    /// below the receiver's per-record limit, and the outbox's byte-budget
    /// batching keeps chunk-heavy batches under the body limit.
    enum SeriesLimits {
        static let pointsPerChunk = 2048
        static let maxChannels = 16
    }

    /// Deterministic chunk identity: the same series and chunk index always
    /// derive the same UUID, so retried captures dedupe at the receiver and
    /// first-write-wins holds. Matches the synthetic sender's derivation.
    static func deterministicChunkID(seriesID: UUID, chunkIndex: Int) -> UUID {
        let seed = "series:\(seriesID.uuidString.lowercased()):\(chunkIndex)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Builds the chunk records for one series. The first channel of
    /// `points` rows is always the time offset in seconds from `parentStart`
    /// (the remaining channels are values in that order), which gives every
    /// chunk record its own accurate interval.
    static func seriesChunkRecords(
        seriesType: String,
        seriesID: UUID,
        parentID: UUID,
        channels: [String],
        points: [[Double]],
        metric: HealthMetric,
        parentStart: Date,
        parentEnd: Date,
        chunkSize: Int = SeriesLimits.pointsPerChunk
    ) -> [HealthRecord] {
        precondition(chunkSize > 0, "chunk size must be positive")
        precondition(!points.isEmpty, "series chunking requires at least one point")
        let chunks = stride(from: 0, to: points.count, by: chunkSize).map { offset in
            Array(points[offset..<Swift.min(offset + chunkSize, points.count)])
        }
        return chunks.enumerated().map { index, chunkPoints in
            let firstOffset = chunkPoints.first?.first ?? 0
            let lastOffset = chunkPoints.last?.first ?? firstOffset
            let start = parentStart.addingTimeInterval(firstOffset)
            let end = parentStart.addingTimeInterval(max(lastOffset, firstOffset))
            return HealthRecord(
                id: deterministicChunkID(seriesID: seriesID, chunkIndex: index),
                metric: metric,
                startDate: min(start, parentEnd),
                endDate: max(end, min(start, parentEnd)),
                metadata: [:],
                data: .series(SeriesData(
                    seriesType: seriesType,
                    seriesID: seriesID,
                    parentID: parentID,
                    chunkIndex: index,
                    channels: channels,
                    points: chunkPoints
                ))
            )
        }
    }
}

extension CanonicalUnit {
    var hkUnit: HKUnit {
        switch self {
        case .count: .count()
        case .countPerMinute: HKUnit.count().unitDivided(by: .minute())
        case .milliseconds: HKUnit.secondUnit(with: .milli)
        case .kilocalories: .kilocalorie()
        case .millimetersOfMercury: .millimeterOfMercury()
        }
    }

    /// The wire spelling of the unit, matching the canonical strings the
    /// app has always sent.
    var unitString: String {
        switch self {
        case .count: "count"
        case .countPerMinute: "count/min"
        case .milliseconds: "ms"
        case .kilocalories: "kcal"
        case .millimetersOfMercury: "mmHg"
        }
    }
}
