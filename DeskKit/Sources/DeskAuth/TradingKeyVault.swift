import Foundation
import LocalAuthentication
import Security

/// Sealed under the Secure Enclave, this device only, openable only by the current biometric enrolment.
/// Only the trading key: it signs orders and nothing else. Best effort — a device that cannot seal falls back to the passkey.
public enum TradingKeyVault {
    public enum Outcome: Sendable {
        case opened(TradingKey)
        case cancelled
        case missing
        case unavailable
    }

    private static let service = "trade.desk.trading-key"

    @discardableResult
    public static func seal(_ key: TradingKey, address: EthereumAddress, network: String) -> Bool {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &error)
        else { return false }
        let data = key.seed.withUnsafeBytes { Data($0) }
        let account = account(address, network)
        SecItemDelete(query(account) as CFDictionary)
        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessControl as String] = access
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public static func open(address: EthereumAddress, network: String, reason: String) async -> Outcome {
        let account = account(address, network)
        return await Task.detached(priority: .userInitiated) { () -> Outcome in
            let context = LAContext()
            context.localizedReason = reason
            var request = query(account)
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            request[kSecUseAuthenticationContext as String] = context
            var result: CFTypeRef?
            switch SecItemCopyMatching(request as CFDictionary, &result) {
            case errSecSuccess:
                guard let data = result as? Data, let key = try? TradingKey(seed: SecureBytes(data)) else {
                    return .missing
                }
                return .opened(key)
            case errSecUserCanceled, errSecAuthFailed:
                return .cancelled
            case errSecItemNotFound:
                return .missing
            default:
                return .unavailable
            }
        }.value
    }

    public static func forget(address: EthereumAddress, network: String) {
        SecItemDelete(query(account(address, network)) as CFDictionary)
    }

    private static func account(_ address: EthereumAddress, _ network: String) -> String {
        network + ":" + address.checksummed.lowercased()
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }
}
