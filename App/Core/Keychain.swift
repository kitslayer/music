import Foundation
import Security

/// Minimal Keychain wrapper for the single credential this app stores.
///
/// The app is re-signed roughly weekly (free Apple developer certificate), and a
/// reinstall keeps the same bundle identifier, so the Keychain item survives --
/// unlike anything kept only in the app container.
enum Keychain {
    private static let service = "com.milescoviello.music"
    private static let account = "server-credentials"

    static func save(_ credentials: SubsonicClient.Credentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }

        // SecItemUpdate cannot create, and SecItemAdd cannot replace, so delete
        // first and add: the simplest correct write for a single item.
        clear()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    static func loadCredentials() -> SubsonicClient.Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else {
            return nil
        }

        return try? JSONDecoder().decode(SubsonicClient.Credentials.self, from: data)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        SecItemDelete(query as CFDictionary)
    }
}
