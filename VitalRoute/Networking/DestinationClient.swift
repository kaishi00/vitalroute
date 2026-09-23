import Foundation

struct DestinationAuthorization {
    let bearerToken: String
}

/// The HTTPS transport boundary for the reference receiver contract
/// (`server/API.md`). Implementations send credential-bearing and
/// health-data requests only to the exact endpoint they are given.
protocol DestinationClient: Sendable {
    /// Sends one batch and returns the receiver's acknowledgment. A return
    /// without throwing means the receiver committed the batch and its
    /// acknowledgment was validated.
    func send(
        _ payload: SyncPayload,
        to endpoint: URL,
        authorization: DestinationAuthorization
    ) async throws -> SyncAcknowledgment

    /// Verifies reachability, TLS, and the credential without sending or
    /// returning health records.
    func testConnection(
        to endpoint: URL,
        authorization: DestinationAuthorization
    ) async throws -> ReceiverHealthResponse
}
