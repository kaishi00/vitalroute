import Foundation

/// Receiver response for the connection test. Contains no health data.
/// `capabilities` is present on receivers implementing the current
/// contract; older receivers omit it. `supportsDeletions` is the gate
/// automatic sync checks.
struct ReceiverHealthResponse: Equatable {
    let status: String
    let service: String
    let apiVersion: Int
    let capabilities: Set<String>

    var supportsDeletions: Bool {
        apiVersion >= 3 && capabilities.contains("deletions")
    }
}
