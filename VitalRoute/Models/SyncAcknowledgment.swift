import Foundation

/// Receiver acknowledgment for an ingested batch (contract v1, `server/API.md`).
/// An HTTP 2xx alone is not evidence of ingestion — the client requires this
/// shape and its `status` value before counting a batch as delivered.
struct SyncAcknowledgment: Equatable {
    let accepted: Int
    let duplicates: Int

    /// Total records the receiver took responsibility for in this batch.
    var delivered: Int { accepted + duplicates }
}

/// Receiver response for the connection test. Contains no health data.
/// `capabilities` is present on contract-v2 receivers; a v1 receiver omits
/// it. `supportsDeletions` is the gate automatic sync checks.
struct ReceiverHealthResponse: Equatable {
    let status: String
    let service: String
    let apiVersion: Int
    let capabilities: Set<String>

    var supportsDeletions: Bool {
        apiVersion >= 2 && capabilities.contains("deletions")
    }
}
