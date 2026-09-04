import Foundation
import Security

/// The Gemini key lives in the keychain, never in UserDefaults or a plist that
/// would ride along in a backup or a screenshot of the app bundle.
enum Keychain {
    private static let service = "com.machinascribe.keys"

    static func set(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ScribeError.keychain("could not save \(account) (status \(status))")
        }
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }
}

enum ScribeError: LocalizedError {
    case keychain(String)
    case missingAPIKey
    case http(Int, String)
    case transcription(String)
    case audio(String)
    /// 429/503 from Gemini. Carries the wait the service asked for, if any.
    case rateLimited(retryAfter: TimeInterval?, detail: String)

    var errorDescription: String? {
        switch self {
        case .keychain(let m):     "Keychain error: \(m)"
        case .missingAPIKey:       "Add your Gemini API key in Settings before recording."
        case .http(let code, let body):
            "Gemini returned \(code). \(body.prefix(300))"
        case .transcription(let m): m
        case .audio(let m):         "Audio error: \(m)"
        case .rateLimited(_, let detail):
            "Gemini is rate limiting this key. \(detail)"
        }
    }
}
