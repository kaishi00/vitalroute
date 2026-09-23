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
    func loadSavedEndpoint() async {
        guard !isLoaded else { return }
        let secureStore = self.secureStore
        let key = storageKey
        let outcome = await Task.detached(priority: .userInitiated) {
            Result { try secureStore.readValue(forKey: key) }
        }.value

        switch outcome {
        case .success(let endpoint):
            savedEndpoint = endpoint ?? ""
            storageError = nil
        case .failure:
            savedEndpoint = ""
            storageError = "The saved destination could not be read from secure storage."
        }
        isLoaded = true
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
