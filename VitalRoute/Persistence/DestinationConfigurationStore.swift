import Foundation
import Observation

@MainActor
@Observable
final class DestinationConfigurationStore {
    @ObservationIgnored private let secureStore: any SecureValueStoring
    private let storageKey = "destination.endpoint"

    private(set) var savedEndpoint: String
    private(set) var storageError: String?

    init(secureStore providedStore: (any SecureValueStoring)? = nil) {
        let secureStore = providedStore ?? KeychainValueStore()
        self.secureStore = secureStore
        do {
            savedEndpoint = try secureStore.readValue(forKey: storageKey) ?? ""
            storageError = nil
        } catch {
            savedEndpoint = ""
            storageError = "The saved destination could not be read from secure storage."
        }
    }

    var isConfigured: Bool {
        !savedEndpoint.isEmpty
    }

    func save(endpoint rawValue: String) throws {
        let configuration = try DestinationConfiguration(endpoint: rawValue)
        let endpoint = configuration.endpoint.absoluteString
        try secureStore.saveValue(endpoint, forKey: storageKey)
        savedEndpoint = endpoint
        storageError = nil
    }

    func clear() throws {
        try secureStore.removeValue(forKey: storageKey)
        savedEndpoint = ""
        storageError = nil
    }
}
