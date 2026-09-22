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
                let energy = workout.statistics(for: energyType)?.sumQuantity() ?? workout.totalEnergyBurned
                if let energy {
                    metadata["activeEnergyKcal"] = String(energy.doubleValue(for: .kilocalorie()))
                }
            }
            if let distance = workout.totalDistance {
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
