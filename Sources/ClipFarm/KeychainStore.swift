import Foundation
import Security

/// The CDN key lives in the login keychain and nowhere else.
///
/// It is never written to disk by ClipFarm, never logged, and never committed. Without
/// a key the CDN destination cannot be switched on.
enum KeychainStore {
    static let service = "dev.haelp.clipfarm"
    static let account = "cdn.haelp.dev"

    /// Keys the CDN issues start with this, which is enough to catch a bad paste.
    static let keyPrefix = "HALP/CDN_"

    private static func query(returningData: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if returningData {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }

    static var apiKey: String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query(returningData: true) as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static var hasAPIKey: Bool { apiKey != nil }

    @discardableResult
    static func setAPIKey(_ key: String?) -> Bool {
        guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            SecItemDelete(query(returningData: false) as CFDictionary)
            return true
        }
        let data = Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let update = SecItemUpdate(
            query(returningData: false) as CFDictionary,
            attributes as CFDictionary
        )
        if update == errSecSuccess { return true }
        if update == errSecItemNotFound {
            var insert = query(returningData: false)
            insert.merge(attributes) { _, new in new }
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    /// Shows the first and last few characters so the settings window can confirm which
    /// key is saved without putting the whole thing on screen.
    static var maskedKey: String? {
        guard let key = apiKey else { return nil }
        let body = key.hasPrefix(keyPrefix) ? String(key.dropFirst(keyPrefix.count)) : key
        guard body.count > 10 else { return keyPrefix + String(repeating: "•", count: 8) }
        return keyPrefix + body.prefix(4) + String(repeating: "•", count: 8) + body.suffix(4)
    }
}
