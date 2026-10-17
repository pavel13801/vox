import Foundation
import Security

/// Small wrapper around the iOS Keychain. Falls back to UserDefaults if the keychain
/// is not available (this can happen with some re-signing tools).
enum Keychain {
    private static let service = "com.pavel.vox.keys"
    private static let fallbackPrefix = "vox.fallback.key."

    static func get(_ key: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let s = String(data: data, encoding: .utf8) {
            return s
        }
        return UserDefaults.standard.string(forKey: fallbackPrefix + key) ?? ""
    }

    static func set(_ value: String, for key: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackPrefix + key)
        guard !trimmed.isEmpty else { return }

        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            UserDefaults.standard.set(trimmed, forKey: fallbackPrefix + key)
        }
    }
}
