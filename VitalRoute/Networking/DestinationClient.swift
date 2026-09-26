import Foundation

struct DestinationAuthorization {
    let bearerToken: String
}

/// The HTTPS transport boundary for the reference receiver contract
/// (`server/API.md`). Implementations send credential-bearing and
/// health-data requests only to the exact endpoint they are given.
protocol DestinationClient: Sendable {
    /// Verifies reachability, TLS, and the credential without sending or
    /// returning health records.
    func testConnection(
        to endpoint: URL,
        authorization: DestinationAuthorization
    ) async throws -> ReceiverHealthResponse

    /// Sends one contract-v3 change batch (additions and deletions) and
    /// returns the receiver's reconciled acknowledgment. A return without
    /// throwing means the receiver committed the batch and accounted for
    /// every change. Both manual and automatic sync deliver through this
    /// single operation: a manual batch is an additions-only change batch.
    func sendChanges(
        _ changes: [SyncChangeEvent],
        batchID: UUID,
        to endpoint: URL,
        authorization: DestinationAuthorization
    ) async throws -> ChangeAcknowledgment
}
