import Foundation
import Observation

@MainActor
@Observable
final class DestinationConfigurationStore {
    @ObservationIgnored private let defaults: UserDefaults
    private let storageKey = "destination.endpoint"

    private(set) var savedEndpoint: String

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.savedEndpoint = defaults.string(forKey: storageKey) ?? ""
    }

    var isConfigured: Bool {
        !savedEndpoint.isEmpty
    }

    func save(endpoint rawValue: String) throws {
        let configuration = try DestinationConfiguration(endpoint: rawValue)
        savedEndpoint = configuration.endpoint.absoluteString
        defaults.set(savedEndpoint, forKey: storageKey)
    }

    func clear() {
        defaults.removeObject(forKey: storageKey)
        savedEndpoint = ""
    }
}
