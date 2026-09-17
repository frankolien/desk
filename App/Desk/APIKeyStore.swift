import DeskAuth
import DeskFlow
import DeskPerpl
import Foundation
import Security

/// Persists only Perpl's opaque identifier. It cannot sign anything by itself; every
/// authenticated request still borrows the transient Face ID-derived trading key.
struct APIKeyStore: Sendable {
    static let standard = APIKeyStore(service: "com.opia.desk.perpl-api-key.v2")

    /// A Perpl API key is enrolled with one exchange on one chain, so each network keeps
    /// its own. Testnet stays on the original service, where existing desks are stored.
    static func forNetwork(_ network: DeskNetwork) -> APIKeyStore {
        network == .testnet ? standard : APIKeyStore(service: "com.opia.desk.perpl-api-key.v2.\(network.rawValue)")
    }

    private let service: String

    init(service: String) { self.service = service }

    func load(for address: EthereumAddress) -> APIKey? {
        var query = baseQuery(for: address)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return APIKey(token)
    }

    func save(_ key: APIKey, for address: EthereumAddress) throws {
        let data = key.withValue { Data($0.utf8) }
        let query = baseQuery(for: address)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure.keychain(added) }
        } else if status != errSecSuccess {
            throw Failure.keychain(status)
        }
    }

    private func baseQuery(for address: EthereumAddress) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: address.checksummed.lowercased()]
    }

    enum Failure: Error { case keychain(OSStatus) }
}
