import Foundation

/// Receiver response for the connection test. Contains no health data.
/// `capabilities` is present on receivers implementing the current
/// contract; older receivers omit it. `supportsDeletions` is the gate
/// automatic sync checks. `storeGeneration` is the receiver's datastore
/// identity (nil from receivers predating it): sync progress is bound to
/// it, so a replaced receiver is detected instead of assumed caught-up.
struct ReceiverHealthResponse: Equatable {
    let status: String
    let service: String
    let apiVersion: Int
    let capabilities: Set<String>
    var storeGeneration: String? = nil

    var supportsDeletions: Bool {
        apiVersion >= 3 && capabilities.contains("deletions")
    }

    /// The datastore identity, when the receiver reports one that parses.
    /// Anything else — absent or unparseable — is nil, and callers must
    /// refuse to sync rather than trust ambiguous identity. Case is
    /// presentation: equality compares the parsed UUID.
    var canonicalStoreGeneration: UUID? {
        storeGeneration.flatMap(UUID.init(uuidString:))
    }
}
