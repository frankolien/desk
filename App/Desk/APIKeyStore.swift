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

    /// Perpl's token and the index of the trading key it was issued for. The two only
    /// work together: a session opened with any other derived key is refused.
    struct Stored: Sendable {
        let apiKey: APIKey
        let tradingIndex: UInt32
    }

    private struct Record: Codable {
        let token: String
        let tradingIndex: UInt32
    }

    func load(for address: EthereumAddress) -> Stored? {
        var query = baseQuery(for: address)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        if let record = try? JSONDecoder().decode(Record.self, from: data), !record.token.isEmpty {
            return Stored(apiKey: APIKey(record.token), tradingIndex: record.tradingIndex)
        }
        // Entries written before the index was recorded hold the bare token, and every
        // one of them was enrolled with the key at the initial index.
        guard let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return Stored(apiKey: APIKey(token), tradingIndex: TradingKeyIndex.initial)
    }

    func tradingIndex(for address: EthereumAddress) -> UInt32 {
        load(for: address)?.tradingIndex ?? TradingKeyIndex.initial
    }

    func save(_ key: APIKey, tradingIndex: UInt32, for address: EthereumAddress) throws {
        let data = try key.withValue { try JSONEncoder().encode(Record(token: $0, tradingIndex: tradingIndex)) }
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
