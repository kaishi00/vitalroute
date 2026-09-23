import Foundation

enum HealthMetric: String, CaseIterable, Codable, Identifiable, Hashable {
    case steps
    case heartRate
    case restingHeartRate
    case heartRateVariability
    case sleep
    case activeEnergy
    case workouts

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .steps: "Steps"
        case .heartRate: "Heart rate"
        case .restingHeartRate: "Resting heart rate"
        case .heartRateVariability: "Heart rate variability"
        case .sleep: "Sleep"
        case .activeEnergy: "Active energy"
        case .workouts: "Workouts"
        }
    }

    var shortDescription: String {
        switch self {
        case .steps: "Daily movement"
        case .heartRate: "Heart rate samples"
        case .restingHeartRate: "Resting heart rate samples"
        case .heartRateVariability: "SDNN measurements"
        case .sleep: "Sleep stages and intervals"
        case .activeEnergy: "Energy burned during activity"
        case .workouts: "Workout intervals and details"
        }
    }

    var symbolName: String {
        switch self {
        case .steps: "figure.walk"
        case .heartRate, .restingHeartRate: "heart"
        case .heartRateVariability: "waveform.path.ecg"
        case .sleep: "bed.double"
        case .activeEnergy: "flame"
        case .workouts: "figure.run"
        }
    }

    var healthKitIdentifier: String {
        switch self {
        case .steps: "HKQuantityTypeIdentifierStepCount"
        case .heartRate: "HKQuantityTypeIdentifierHeartRate"
        case .restingHeartRate: "HKQuantityTypeIdentifierRestingHeartRate"
        case .heartRateVariability: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
        case .sleep: "HKCategoryTypeIdentifierSleepAnalysis"
        case .activeEnergy: "HKQuantityTypeIdentifierActiveEnergyBurned"
        case .workouts: "HKWorkoutTypeIdentifier"
        }
    }

    init?(healthKitIdentifier: String) {
        guard let metric = Self.allCases.first(where: { $0.healthKitIdentifier == healthKitIdentifier }) else {
            return nil
        }
        self = metric
    }
}
