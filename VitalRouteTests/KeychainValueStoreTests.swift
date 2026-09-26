import Security
import XCTest
@testable import VitalRoute

/// Exercises the real Keychain (the hosted test runner's keychain is
/// per-instance and these items are unique per test and cleaned up). Covers
/// the accessibility class written at insert time and the in-place migration
/// of items written by earlier builds.
final class KeychainValueStoreTests: XCTestCase {
    private var service: String {
        Bundle.main.bundleIdentifier ?? "com.milim.vitalroute"
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
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
        let account = "test.accessibility.save"
        cleanup(account)
        defer { cleanup(account) }

        let store = KeychainValueStore()
        try store.saveValue("https://health.example.org/v1/records", forKey: account)

        XCTAssertEqual(
            accessibility(of: account),
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            "destination items must stay readable from locked-device background launches"
        )
        XCTAssertEqual(try store.readValue(forKey: account), "https://health.example.org/v1/records")
    }

    func testMigrationUpgradesExistingItemsInPlace() throws {
        let account = "test.accessibility.migrate"
        cleanup(account)
        defer { cleanup(account) }

        // An item written by build 6 and earlier: readable only while
        // unlocked, never migrated across devices.
        var addQuery = baseQuery(account)
        addQuery[kSecValueData as String] = Data("https://health.example.org/v1/records".utf8)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        XCTAssertEqual(SecItemAdd(addQuery as CFDictionary, nil), errSecSuccess)

        let store = KeychainValueStore()
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

    func testMigrationWithNoItemsDoesNotThrow() throws {
        let account = "test.accessibility.empty"
        cleanup(account)

        // Nothing is seeded: migration across an empty keychain (a fresh
        // install, or nothing configured yet) must be a no-op, not an error.
        let store = KeychainValueStore()
        try store.migrateToBackgroundAccessibility()
    }
}
