import Foundation

struct DestinationAuthorization {
    let bearerToken: String
}

/// The future HTTPS transport boundary. This initial app defines the contract but sends no records.
protocol DestinationClient {
    func send(
        _ payload: SyncPayload,
        to configuration: DestinationConfiguration,
        authorization: DestinationAuthorization?
    ) async throws
}
