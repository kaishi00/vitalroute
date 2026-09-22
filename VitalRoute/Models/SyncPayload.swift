import Foundation

struct SyncPayload: Codable, Equatable {
    let schemaVersion: Int
    let createdAt: Date
    let records: [HealthRecord]

    init(schemaVersion: Int = 1, createdAt: Date = Date(), records: [HealthRecord]) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.records = records
    }
}

enum SyncPayloadEncoder {
    static func encode(_ payload: SyncPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }
}
