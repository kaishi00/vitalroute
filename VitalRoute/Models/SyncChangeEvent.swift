import Foundation

/// A deleted Apple Health sample as reported by an anchored query's
/// deleted-object results. Deletion notifications cannot be recovered by
/// re-querying later, so they are captured into the outbox immediately.
struct DeletedRecord: Codable, Equatable {
    let id: UUID
    let metric: HealthMetric
    let startDate: Date
    let endDate: Date
}

/// One durable outbox event: an addition (full record) or a deletion.
enum SyncChangeEvent: Equatable {
    case upsert(HealthRecord)
    case delete(DeletedRecord)

    /// Stable event identity used for dedupe after crash-replay: the sample
    /// UUID for additions, a deletion-prefixed UUID for deletions.
    var eventID: String {
        switch self {
        case .upsert(let record):
            return record.id.uuidString.lowercased()
        case .delete(let deleted):
            return "del-" + deleted.id.uuidString.lowercased()
        }
    }

    var sampleID: UUID {
        switch self {
        case .upsert(let record):
            record.id
        case .delete(let deleted):
            deleted.id
        }
    }

    var metric: HealthMetric {
        switch self {
        case .upsert(let record):
            record.metric
        case .delete(let deleted):
            deleted.metric
        }
    }
}

extension SyncChangeEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case record
        case deleted
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .upsert(let record):
            try container.encode("upsert", forKey: .kind)
            try container.encode(record, forKey: .record)
        case .delete(let deleted):
            try container.encode("delete", forKey: .kind)
            try container.encode(deleted, forKey: .deleted)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "upsert":
            self = .upsert(try container.decode(HealthRecord.self, forKey: .record))
        case "delete":
            self = .delete(try container.decode(DeletedRecord.self, forKey: .deleted))
        case let other:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown change kind \(other)."
            )
        }
    }
}

/// Encodes contract-v2 change batches (`server/API.md`). Dates use the same
/// ISO 8601 millisecond spelling as v1 payloads.
enum ChangeBatchEncoder {
    static func encode(batchID: UUID, createdAt: Date, changes: [SyncChangeEvent]) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        struct WireChange: Encodable {
            let kind: String
            let record: HealthRecord?
            let id: UUID?
            let metric: HealthMetric?
            let startDate: Date?
            let endDate: Date?
        }

        struct WireBatch: Encodable {
            let schemaVersion = 2
            let createdAt: String
            let batchId: String
            let changes: [WireChange]
        }

        let batch = WireBatch(
            createdAt: formatter.string(from: createdAt),
            batchId: batchID.uuidString.lowercased(),
            changes: changes.map { change in
                switch change {
                case .upsert(let record):
                    WireChange(kind: "upsert", record: record, id: nil, metric: nil, startDate: nil, endDate: nil)
                case .delete(let deleted):
                    WireChange(kind: "delete", record: nil, id: deleted.id, metric: deleted.metric, startDate: deleted.startDate, endDate: deleted.endDate)
                }
            }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(batch)
    }
}

/// Receiver acknowledgment for a v2 change batch. An HTTP 2xx alone is not
/// evidence: the counts must reconcile against what was sent.
struct ChangeAcknowledgment: Equatable {
    let accepted: Int
    let duplicates: Int
    let superseded: Int
    let appliedDeletions: Int
    let duplicateDeletions: Int

    /// The contract guarantees the receiver took responsibility for every
    /// change in the batch.
    func reconciles(upsertsSent: Int, deletesSent: Int) -> Bool {
        let upsertsAccounted = accepted + duplicates + superseded
        let deletesAccounted = appliedDeletions + duplicateDeletions
        return upsertsAccounted == upsertsSent && deletesAccounted == deletesSent
    }
}

enum ChangeAcknowledgmentDecoder {
    static func decode(_ data: Data) throws -> ChangeAcknowledgment {
        struct Shape: Decodable {
            let status: String
            let accepted: Int
            let duplicates: Int
            let superseded: Int
            let appliedDeletions: Int
            let duplicateDeletions: Int
        }
        let shape: Shape
        do {
            shape = try JSONDecoder().decode(Shape.self, from: data)
        } catch {
            throw DestinationClientError.malformedAcknowledgment
        }
        guard shape.status == "accepted" else {
            throw DestinationClientError.malformedAcknowledgment
        }
        let counts = [shape.accepted, shape.duplicates, shape.superseded, shape.appliedDeletions, shape.duplicateDeletions]
        guard counts.allSatisfy({ $0 >= 0 }) else {
            throw DestinationClientError.malformedAcknowledgment
        }
        return ChangeAcknowledgment(
            accepted: shape.accepted,
            duplicates: shape.duplicates,
            superseded: shape.superseded,
            appliedDeletions: shape.appliedDeletions,
            duplicateDeletions: shape.duplicateDeletions
        )
    }
}
