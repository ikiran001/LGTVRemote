import Foundation
import Security

final class KeychainStore {
    static let shared = KeychainStore()
    private init() {}

    private let service = "LGRemoteMVP.clientKey"

    func clientKey(for ip: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ip,
            kSecReturnData as String: true,
            // 🔑 iCloud Keychain sync
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func saveClientKey(_ key: String, for ip: String) {
        let data = Data(key.utf8)

        // delete any previous value (local or synced)
        let baseDelete: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ip,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        SecItemDelete(baseDelete as CFDictionary)

        // add new, synced via iCloud Keychain
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ip,
            kSecValueData as String: data,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any
        ]
        SecItemAdd(add as CFDictionary, nil)
    }
}

