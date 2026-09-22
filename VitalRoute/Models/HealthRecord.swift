import Foundation

struct HealthRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let metric: HealthMetric
    let value: Double
    let unit: String
    let startDate: Date
    let endDate: Date
    let sourceName: String?
    let deviceName: String?
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        metric: HealthMetric,
        value: Double,
        unit: String,
        startDate: Date,
        endDate: Date,
        sourceName: String? = nil,
        deviceName: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.metric = metric
        self.value = value
        self.unit = unit
        self.startDate = startDate
        self.endDate = endDate
        self.sourceName = sourceName
        self.deviceName = deviceName
        self.metadata = metadata
    }

    var displayValue: String {
        if unit == "s" {
            return "\(Int(value / 60)) min"
        }
        return "\(value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)"
    }
}
