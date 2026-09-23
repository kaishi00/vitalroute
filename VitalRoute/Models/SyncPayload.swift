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
    /// Dates travel as ISO 8601 with fractional seconds — millisecond
    /// precision; sub-millisecond digits are truncated by design. The
    /// built-in `.iso8601` strategy would truncate to whole seconds.
    private static func makeFractionalDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static func encode(_ payload: SyncPayload) throws -> Data {
        // One formatter per call rather than a shared static: cheap here, and
        // immune to any thread-safety doubt about formatter sharing.
        let dateFormatter = makeFractionalDateFormatter()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    static func decode(_ data: Data) throws -> SyncPayload {
        // A formatter with fractional seconds rejects whole-second strings,
        // so decoding accepts either spelling.
        let fractionalDateFormatter = makeFractionalDateFormatter()
        let plainDateFormatter = ISO8601DateFormatter()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let date = fractionalDateFormatter.date(from: raw) ?? plainDateFormatter.date(from: raw)
            guard let date else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO 8601 date string."
                )
            }
            return date
        }
        return try decoder.decode(SyncPayload.self, from: data)
    }
}
