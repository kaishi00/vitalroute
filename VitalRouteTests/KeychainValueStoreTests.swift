import Security
import XCTest
@testable import VitalRoute

/// Exercises the real Keychain (the hosted test runner's keychain is
/// per-instance). Everything happens under a dedicated test service string:
/// the production store is service-scoped to the app's bundle identifier,
/// and the migration is service-wide, so tests must never touch accounts the
/// app itself might have written.
final class KeychainValueStoreTests: XCTestCase {
    /// Throws XCTSkip when the runner's keychain denies access. GitHub
    /// Actions runners reject SecItemAdd from the hosted, ad-hoc-signed
    /// test host with errSecMissingEntitlement (-34018) — the environment
    /// flag does not reach the simulator test process, so detect the
    /// condition directly with a throwaway write.
    private func requireKeychainAccess() throws {
        let probe = "test.keychain-probe.\(UUID().uuidString)"
        defer { cleanup(probe) }
        var add = baseQuery(probe)
        add[kSecValueData as String] = Data("probe".utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            throw XCTSkip("simulator keychain denies access on this runner (-34018)")
        }
        if status != errSecSuccess {
            XCTFail("keychain probe failed with status \(status)")
        }
    }

    /// Unique per run; never the app's real service.
    private let testService = "com.milim.vitalroute.tests.\(UUID().uuidString)"

    private var store: KeychainValueStore {
        KeychainValueStore(service: testService)
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService,
            kSecAttrAccount as String: account
        ]
    }

    private func cleanup(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private func accessibility(of account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            XCTFail("SecItemCopyMatching failed with status \(status)")
            return nil
        }
        // kSecAttrAccessible is a toll-free-bridged CFString; comparing the
        // bridged String against the bridged constant avoids a CF downcast.
        return (result as? [String: Any])?[kSecAttrAccessible as String] as? String
    }

    func testSaveWritesBackgroundAccessibleDeviceOnlyItems() throws {
        try requireKeychainAccess()
        let account = "test.accessibility.save"
        cleanup(account)
        defer { cleanup(account) }

        let store = store
        try store.saveValue("https://health.example.org/v1/records", forKey: account)

        XCTAssertEqual(
            accessibility(of: account),
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            "destination items must stay readable from locked-device background launches"
        )
        XCTAssertEqual(try store.readValue(forKey: account), "https://health.example.org/v1/records")
    }

    func testMigrationUpgradesExistingItemsInPlace() throws {
        try requireKeychainAccess()
        let account = "test.accessibility.migrate"
        cleanup(account)
        defer { cleanup(account) }

        // An item written by build 6 and earlier: readable only while
        // unlocked, never migrated across devices.
        var addQuery = baseQuery(account)
        addQuery[kSecValueData as String] = Data("https://health.example.org/v1/records".utf8)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        XCTAssertEqual(SecItemAdd(addQuery as CFDictionary, nil), errSecSuccess)

        try store.migrateToBackgroundAccessibility()

        XCTAssertEqual(
            accessibility(of: account),
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            "migration must upgrade existing items, not only future inserts"
        )
        XCTAssertEqual(
            try store.readValue(forKey: account),
            "https://health.example.org/v1/records",
            "migration must preserve the stored value"
        )
    }

    func testMigrationCoversEveryItemUnderTheService() throws {
        try requireKeychainAccess()
        // The migration is service-scoped on purpose: the endpoint and every
        // per-destination credential need background readability. Pin that
        // both item kinds are upgraded by one call.
        let endpointAccount = "destination.endpoint"
        let credentialAccount = "destination.credential.abc123"
        cleanup(endpointAccount)
        cleanup(credentialAccount)
        defer {
            cleanup(endpointAccount)
            cleanup(credentialAccount)
        }
        for account in [endpointAccount, credentialAccount] {
            var addQuery = baseQuery(account)
            addQuery[kSecValueData as String] = Data("value-for-\(account)".utf8)
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            XCTAssertEqual(SecItemAdd(addQuery as CFDictionary, nil), errSecSuccess)
        }

        try store.migrateToBackgroundAccessibility()

        XCTAssertEqual(
            accessibility(of: endpointAccount),
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        XCTAssertEqual(
            accessibility(of: credentialAccount),
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        XCTAssertEqual(try store.readValue(forKey: endpointAccount), "value-for-\(endpointAccount)")
        XCTAssertEqual(try store.readValue(forKey: credentialAccount), "value-for-\(credentialAccount)")
    }

    func testMigrationWithNoItemsDoesNotThrow() throws {
        try requireKeychainAccess()
        let account = "test.accessibility.empty"
        cleanup(account)

        // With nothing seeded under this service, the migration must take
        // its not-found path and succeed — the not-throwing contract for a
        // fresh install. The dedicated test service makes "empty" real.
        try store.migrateToBackgroundAccessibility()
    }
}
