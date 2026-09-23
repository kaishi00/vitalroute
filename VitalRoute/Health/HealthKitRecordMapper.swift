import Foundation
import HealthKit

enum HealthKitRecordMapper {
    static func sampleType(for metric: HealthMetric) -> HKSampleType? {
        switch metric {
        case .steps:
            HKObjectType.quantityType(forIdentifier: .stepCount)
        case .heartRate:
            HKObjectType.quantityType(forIdentifier: .heartRate)
        case .restingHeartRate:
            HKObjectType.quantityType(forIdentifier: .restingHeartRate)
        case .heartRateVariability:
            HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)
        case .sleep:
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        case .activeEnergy:
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)
        case .workouts:
            HKObjectType.workoutType()
        }
    }

    static func makeRecord(from sample: HKSample, metric: HealthMetric) -> HealthRecord? {
        var value: Double
        var unit: String
        var metadata: [String: String] = [:]

        switch metric {
        case .steps:
            guard let quantity = sample as? HKQuantitySample else { return nil }
            value = quantity.quantity.doubleValue(for: .count())
            unit = "count"
        case .heartRate, .restingHeartRate:
            guard let quantity = sample as? HKQuantitySample else { return nil }
            value = quantity.quantity.doubleValue(for: HKUnit.count().unitDivided(by: HKUnit.minute()))
            unit = "count/min"
        case .heartRateVariability:
            guard let quantity = sample as? HKQuantitySample else { return nil }
            value = quantity.quantity.doubleValue(for: HKUnit.secondUnit(with: .milli))
            unit = "ms"
        case .activeEnergy:
            guard let quantity = sample as? HKQuantitySample else { return nil }
            value = quantity.quantity.doubleValue(for: .kilocalorie())
            unit = "kcal"
        case .sleep:
            guard let category = sample as? HKCategorySample else { return nil }
            value = sample.endDate.timeIntervalSince(sample.startDate)
            unit = "s"
            metadata["sleepStage"] = sleepStage(for: category.value)
        case .workouts:
            guard let workout = sample as? HKWorkout else { return nil }
            value = workout.duration
            unit = "s"
            metadata["activityTypeCode"] = String(workout.workoutActivityType.rawValue)
            if let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
                if let energy = workout.statistics(for: energyType)?.sumQuantity() {
                    metadata["activeEnergyKcal"] = String(energy.doubleValue(for: .kilocalorie()))
                }
            }
            if let distance = workoutDistance(statisticsByType: { workout.statistics(for: $0)?.sumQuantity() }) {
                metadata["distanceMeters"] = String(distance.doubleValue(for: .meter()))
            }
        }

        return HealthRecord(
            id: sample.uuid,
            metric: metric,
            value: value,
            unit: unit,
            startDate: sample.startDate,
            endDate: sample.endDate,
            sourceName: sample.sourceRevision.source.name,
            deviceName: sample.device?.name,
            metadata: metadata
        )
    }

    /// Workouts record distance under activity-specific quantity types, and
    /// multisport workouts can carry several; summing all measured types
    /// matches the legacy totalDistance behavior. statistics(for:) returns
    /// nil for types a workout does not measure.
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
    /// a live HKHealthStore; makeRecord supplies `workout.statistics(for:)`.
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

    private static func sleepStage(for rawValue: Int) -> String {
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
            "unknown"
        @unknown default:
            "unknown"
        }
    }
}
