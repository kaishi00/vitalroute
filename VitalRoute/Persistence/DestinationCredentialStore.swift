import CryptoKit
import Foundation
import Observation

enum DestinationCredentialStoreError: Error, Equatable, LocalizedError {
    case emptyToken

    var errorDescription: String? {
        switch self {
        case .emptyToken:
            "Enter the API key for this destination."
        }
    }
}

/// Keychain-backed storage for the destination API key.
///
/// Credentials are namespaced by a SHA-256 digest of the endpoint they belong
/// to, so a destination change can never silently reuse another destination's
/// key: each endpoint has its own Keychain entry. The token is kept out of
/// preferences, logs, and observable state (a boolean and the owning endpoint
/// are what the UI renders).
@MainActor
@Observable
final class DestinationCredentialStore {
    @ObservationIgnored private let secureStore: any SecureValueStoring

    private(set) var isLoaded = false
    /// The endpoint the loaded `hasCredential` state describes.
    private(set) var credentialEndpoint = ""
    private(set) var hasCredential = false
    private(set) var storageError: String?
    /// Bumped by every credential write.
    ///
    /// Nonsecret by construction, and the only observable signal that an
    /// existing credential was *replaced*: a replacement for the same
    /// endpoint changes neither `hasCredential` nor `credentialEndpoint`, and
    /// the token itself is deliberately not observable. Observers use this to
    /// learn that the credential in use has changed.
    private(set) var credentialRevision = 0
    /// The actual token for `credentialEndpoint`; used only to build requests,
    /// never logged. Observable-change tracking is deliberately skipped.
    @ObservationIgnored private(set) var loadedToken: String?

    /// Bumped by every save/remove so a stale in-flight read cannot clobber
    /// settled state — same contract as `DestinationConfigurationStore`.
    @ObservationIgnored private var loadGeneration = 0

    init(secureStore providedStore: (any SecureValueStoring)? = nil) {
        self.secureStore = providedStore ?? KeychainValueStore()
    }

    static func storageKey(for endpoint: String) -> String {
        let digest = SHA256.hash(data: Data(endpoint.utf8))
        return "destination.credential." + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Loads the credential for an endpoint asynchronously (Keychain reads
    /// can block; they run off the main actor). No-ops when the store is
    /// already settled for this endpoint. A save/remove that lands while the
    /// read is in flight wins over the read. A read that fails (locked
    /// device) leaves the last settled state standing and keeps this
    /// endpoint retryable instead of settling it as "no credential".
    func loadCredential(for endpoint: String) async {
        guard !isLoaded || credentialEndpoint != endpoint else {
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        let secureStore = self.secureStore
        let key = Self.storageKey(for: endpoint)
        let outcome = await Task.detached(priority: .userInitiated) {
            Result { try secureStore.readValue(forKey: key) }
        }.value

        guard generation == loadGeneration else {
            return
        }
        apply(token: try? outcome.get(), endpoint: endpoint, readFailed: outcome.isFailure)
    }

    func saveCredential(_ token: String, for endpoint: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DestinationCredentialStoreError.emptyToken
        }
        try secureStore.saveValue(trimmed, forKey: Self.storageKey(for: endpoint))
        loadGeneration += 1
        loadedToken = trimmed
        hasCredential = true
        credentialEndpoint = endpoint
        storageError = nil
        isLoaded = true
        credentialRevision += 1
    }

    /// Removes the credential for one endpoint. Call this when the endpoint
    /// changes (with the previous endpoint) or the destination is removed.
    func removeCredential(for endpoint: String) throws {
        try secureStore.removeValue(forKey: Self.storageKey(for: endpoint))
        loadGeneration += 1
        if credentialEndpoint == endpoint {
            loadedToken = nil
            hasCredential = false
            credentialEndpoint = endpoint
            isLoaded = true
        }
        credentialRevision += 1
    }

    private func apply(token: String?, endpoint: String, readFailed: Bool) {
        if readFailed {
            // Transient secure-storage unavailability must not look like "no
            // credential": the last settled state stands (for a fresh store
            // that means nothing loaded yet), the store stays retryable for
            // this endpoint, and the error is surfaced.
            storageError = "The saved API key could not be read from secure storage. VitalRoute will retry when secure storage is available."
            return
        }
        loadedToken = token
        hasCredential = token != nil
        credentialEndpoint = endpoint
        storageError = nil
        isLoaded = true
    }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self {
            return true
        }
        return false
    }
}
