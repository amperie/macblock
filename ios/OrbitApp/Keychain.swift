import Foundation
import Security

struct ConnectionKeychain {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Bundle.main.bundleIdentifier ?? "OrbitPhone",
         kSecAttrAccount as String: "phone-connection"]
    }
    func load() throws -> PhoneConnection? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw OrbitFailure.credentialStorage }
        return try JSONDecoder().decode(PhoneConnection.self, from: data)
    }
    func save(_ connection: PhoneConnection) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(connection),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw OrbitFailure.credentialStorage
            }
        } else if status != errSecSuccess { throw OrbitFailure.credentialStorage }
    }
}
