import Foundation
import Observation

@MainActor
@Observable
final class DestinationConfigurationStore {
    @ObservationIgnored private let secureStore: any SecureValueStoring
    private let storageKey = "destination.endpoint"

    private(set) var savedEndpoint = ""
    private(set) var storageError: String?
    private(set) var isLoaded = false

    init(secureStore providedStore: (any SecureValueStoring)? = nil) {
        self.secureStore = providedStore ?? KeychainValueStore()
    }

    var isConfigured: Bool {
        !savedEndpoint.isEmpty
    }

    /// Loads the saved endpoint asynchronously. Keychain reads can block, so
    /// they run off the main actor instead of during app startup; call this
    /// from the UI (e.g. a `.task` modifier) and render from `isLoaded`.
    /// No-ops once the store state has settled (load completed, or a
    /// save/clear already established authoritative state).
    ///
    /// A read *failure* — transient secure-storage unavailability, e.g. a
    /// locked-device background launch — does not settle the store: the
    /// endpoint keeps its previous value, `isLoaded` stays false so later
    /// calls retry, and `storageError` says what is wrong. Settling a
    /// failure as "no destination" is what erased the saved endpoint on
    /// build 6.
    func loadSavedEndpoint() async {
        guard !isLoaded else { return }
        let secureStore = self.secureStore
        let key = storageKey
        let outcome = await Task.detached(priority: .userInitiated) {
            Result { try secureStore.readValue(forKey: key) }
        }.value

        // save()/clear() may have settled authoritative state while the read
        // was in flight; keep theirs over the stale read.
        guard !isLoaded else { return }

        switch outcome {
        case .success(let endpoint):
            savedEndpoint = endpoint ?? ""
            storageError = nil
            isLoaded = true
        case .failure:
            storageError = "The saved destination could not be read from secure storage. VitalRoute will retry when secure storage is available."
        }
    }

    func save(endpoint rawValue: String) throws {
        let configuration = try DestinationConfiguration(endpoint: rawValue)
        let endpoint = configuration.endpoint.absoluteString
        try secureStore.saveValue(endpoint, forKey: storageKey)
        savedEndpoint = endpoint
        storageError = nil
        isLoaded = true
    }

    func clear() throws {
        try secureStore.removeValue(forKey: storageKey)
        savedEndpoint = ""
        storageError = nil
        isLoaded = true
    }
}
