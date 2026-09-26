import Foundation
import Security

// The SecItem API family is thread-safe and the conformers hold no mutable
// state, so reads can safely run off the main actor (Sendable). The store
// keeps app-facing observable state; this layer only moves values.
protocol SecureValueStoring: Sendable {
    func readValue(forKey key: String) throws -> String?
    func saveValue(_ value: String, forKey key: String) throws
    func removeValue(forKey key: String) throws
    /// Upgrades every stored item to the background-readable accessibility
    /// class. Idempotent, preserves values, and succeeds trivially when
    /// nothing is stored. Fails while the device is locked (the upgrade
    /// itself needs an unlocked keychain), so callers retry it on unlock.
    func migrateToBackgroundAccessibility() throws
}

/// The accessibility class for items automatic sync reads from a background
/// launch, which iOS may run while the device is locked. Apple's Keychain
/// Data Protection guidance: "Apps that use background refresh services can
/// use kSecAttrAccessibleAfterFirstUnlock for keychain items that need to be
/// accessed during background updates." The device-only variant keeps the
/// endpoint and its API key out of backups and off every other device.
private let vitalRouteKeychainAccessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

final class KeychainValueStore: SecureValueStoring {
    private let service = Bundle.main.bundleIdentifier ?? "com.milim.vitalroute"

    func readValue(forKey key: String) throws -> String? {
        var query = baseQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainValueStoreError.status(status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainValueStoreError.invalidData
        }
        return value
    }

    func saveValue(_ value: String, forKey key: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(forKey: key)
        let updateAttributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = vitalRouteKeychainAccessibility
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainValueStoreError.status(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainValueStoreError.status(updateStatus)
        }
    }

    func removeValue(forKey key: String) throws {
        let status = SecItemDelete(baseQuery(forKey: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainValueStoreError.status(status)
        }
    }

    /// One service-scoped update upgrades every stored item — the endpoint
    /// and all per-destination credentials, without reading any value. Items
    /// inserted by earlier builds carried `WhenUnlockedThisDeviceOnly`, which
    /// is unreadable from a locked-device launch; upgrading in place is what
    /// makes the stored configuration reachable before the next save.
    func migrateToBackgroundAccessibility() throws {
        let query = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let attributes = [kSecAttrAccessible as String: vitalRouteKeychainAccessibility]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainValueStoreError.status(status)
        }
    }

    private func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}

private enum KeychainValueStoreError: LocalizedError {
    case status(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .status(let status):
            "Secure storage failed with status \(status)."
        case .invalidData:
            "The saved secure value could not be read."
        }
    }
}
