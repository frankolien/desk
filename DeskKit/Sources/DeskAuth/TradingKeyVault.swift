import Foundation
import LocalAuthentication
import Security

/// The trading key at rest.
///
/// Sealed rather than stored. The item is written under the Secure Enclave's protection
/// with the current biometric enrolment as the only thing that can open it: it cannot be
/// read without Face ID, cannot leave this device, is not backed up, and is invalidated
/// the moment the enrolment changes. The bytes on disk are useless to anyone who is not
/// the face that put them there, which is the whole difference from a seed phrase.
///
/// Only the trading key goes in. It signs orders on Perpl and nothing else — deposits and
/// withdrawals are signed by the wallet key, which the passkey derives every time and
/// which is never written anywhere. The worst case for a sealed trading key is therefore
/// a trade on the account, which is the same worst case as the key in memory, and the
/// gain is that reopening the app costs one Face ID rather than a passkey ceremony.
///
/// Everything here is best effort: a device without a passcode cannot seal, and a
/// simulator usually cannot either. The caller falls back to deriving the key from the
/// passkey, which is what it did before the vault existed.
public enum TradingKeyVault {
    public enum Outcome: Sendable {
        case opened(TradingKey)
        /// Face ID was refused or dismissed. The person said no; do not ask again another way.
        case cancelled
        /// Nothing sealed for this account on this device, or the enrolment changed.
        case missing
        /// The keychain could not be used at all.
        case unavailable
    }

    private static let service = "trade.desk.trading-key"

    /// Seals the key. Returns false when this device cannot, which is not an error to show.
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

    /// Opens the key with one Face ID prompt. Blocks on the prompt, so it runs off the
    /// main actor and the caller awaits it.
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
