// TNTCredentials — the only sanctioned home for the User's OpenAI BYOK
// API key. Wraps `kSecClassGenericPassword` Keychain operations so that
// (a) the key never lives in `UserDefaults` or any plaintext config,
// (b) `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` keeps the key
// off backups and pinned to the local device, and
// (c) tests can inject a per-test `service` prefix so the developer's
// real `com.tnt.app` Keychain entry is never touched.

import Foundation
import Security

public enum TNTCredentialsError: Error, Equatable, Sendable {
    case invalidKey
    case itemNotFound
    case decodingFailed
    case keychain(OSStatus)
}

public enum TNTCredentials {

    /// Production Keychain service. The acceptance test grep walks
    /// `~/.tnt`, `~/Library/Preferences/com.tnt.app*`, and
    /// `~/Library/Application Support/com.tnt.app*` for the test key —
    /// the Keychain itself is the only place writes land.
    public static let defaultService: String = "com.tnt.app"

    /// Account name shared by every OpenAI key entry.
    public static let account: String = "openai-api-key"

    // MARK: - Public API (issue #8 contract)

    public static func openAIKey() throws -> String {
        try openAIKey(service: defaultService)
    }

    public static func setOpenAIKey(_ key: String) throws {
        try setOpenAIKey(key, service: defaultService)
    }

    public static func deleteOpenAIKey() throws {
        try deleteOpenAIKey(service: defaultService)
    }

    // MARK: - Service-scoped variants (used by tests + the Replace flow)

    public static func openAIKey(service: String) throws -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let key = String(data: data, encoding: .utf8) else {
                throw TNTCredentialsError.decodingFailed
            }
            return key
        case errSecItemNotFound:
            throw TNTCredentialsError.itemNotFound
        default:
            throw TNTCredentialsError.keychain(status)
        }
    }

    public static func setOpenAIKey(_ key: String, service: String) throws {
        guard !key.isEmpty else {
            throw TNTCredentialsError.invalidKey
        }
        let data = Data(key.utf8)

        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]

        // Try in-place update first so we don't accidentally double-add
        // when the User cycles their key.
        let updateAttrs: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            // No existing entry — add it.
            var addAttrs = baseQuery
            addAttrs[kSecValueData] = data
            addAttrs[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addAttrs as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw TNTCredentialsError.keychain(addStatus)
            }
        default:
            throw TNTCredentialsError.keychain(updateStatus)
        }
    }

    public static func deleteOpenAIKey(service: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        // `errSecItemNotFound` is fine — deleting an absent item is a
        // no-op so the Replace-API-Key flow can call delete + set.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TNTCredentialsError.keychain(status)
        }
    }
}
