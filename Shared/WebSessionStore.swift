import Foundation
import Security

/// Places a session captured via in-app sign-in into an AI Usage-only Keychain item.
///
/// Never reads or writes another app's credentials. Sharing one would make macOS swap its
/// partition list to the writer, causing the other side to be repeatedly prompted for a
/// password — so each collection route keeps its own item.
struct WebSessionStore {
    let service: String

    private func query(account: String = NSUserName()) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load(validate: (String) -> Bool) -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            query().merging([
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]) { _, new in new } as CFDictionary,
            &item
        )
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              validate(value)
        else { return nil }
        return value
    }

    @discardableResult
    func save(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let update = SecItemUpdate(
            query() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }

        return SecItemAdd(
            query().merging([
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]) { _, new in new } as CFDictionary,
            nil
        ) == errSecSuccess
    }

    /// The time it was last saved. Shows "when did I sign in" once the session expires.
    /// Reads only Keychain's attributes without touching the contents, so no decryption of the value happens.
    func savedAt() -> Date? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            query().merging([
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]) { _, new in new } as CFDictionary,
            &item
        )
        guard status == errSecSuccess,
              let attributes = item as? [String: Any],
              let saved = attributes[kSecAttrModificationDate as String] as? Date
        else { return nil }
        return saved
    }

    @discardableResult
    func remove() -> Bool {
        let status = SecItemDelete(query() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
