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

    /// The key, read from the keychain once and then kept in memory.
    ///
    /// Every read can make macOS ask for permission, so reading on demand from the
    /// settings window, the destination checks and the uploader meant several prompts
    /// per launch. The value is fetched once and reused, and the cache is cleared
    /// whenever the key is written or removed.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedKey: String??

    static var apiKey: String? {
        cacheLock.withLock {
            if let cachedKey { return cachedKey }
            let fetched = readFromKeychain()
            cachedKey = fetched
            return fetched
        }
    }

    private static func readFromKeychain() -> String? {
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

    /// Drops the cached value, so the next read goes back to the keychain.
    static func forgetCachedKey() {
        cacheLock.withLock { cachedKey = nil }
    }

    @discardableResult
    static func setAPIKey(_ key: String?) -> Bool {
        defer { forgetCachedKey() }
        guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            SecItemDelete(query(returningData: false) as CFDictionary)
            return true
        }
        let data = Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        // Delete and re-add rather than update. A keychain item keeps the access list
        // of whatever process created it, and updating the value leaves that list
        // alone. Writing it fresh from inside ClipFarm makes ClipFarm the owner, which
        // is what stops macOS asking for permission on later launches.
        SecItemDelete(query(returningData: false) as CFDictionary)
        var insert = query(returningData: false)
        insert.merge(attributes) { _, new in new }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    /// Takes ownership of a key that something else wrote.
    ///
    /// A key added from the command line belongs to `/usr/bin/security`, so ClipFarm
    /// has to ask for permission every time it reads. Rewriting the item through
    /// ClipFarm rebuilds the access list, after which reads are silent. This costs one
    /// prompt, once.
    ///
    /// Stale entries pile up the same way. A signature change leaves the old app
    /// reference behind as a broken entry that keeps prompting, and rewriting clears
    /// those too.
    @discardableResult
    static func adoptExistingKeyIfNeeded() -> Bool {
        let flag = "keychainItemAdopted"
        guard !UserDefaults.standard.bool(forKey: flag) else { return false }

        guard let existing = apiKey else {
            // Nothing to adopt. Anything saved later is written by ClipFarm anyway.
            UserDefaults.standard.set(true, forKey: flag)
            return false
        }

        let rewritten = setAPIKey(existing)
        UserDefaults.standard.set(true, forKey: flag)
        if rewritten {
            Log.info("Took ownership of the CDN key, so macOS stops asking for it")
        } else {
            Log.error("Could not take ownership of the CDN key")
        }
        return rewritten
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
