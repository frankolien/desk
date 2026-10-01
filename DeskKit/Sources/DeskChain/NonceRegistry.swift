import DeskAuth
import Foundation

/// Local nonce tracking, because Monad's `pending` tag equals `latest`: an in-flight
/// transaction does not bump `eth_getTransactionCount`.
public actor NonceRegistry {
    private var reserved: [String: UInt64] = [:]

    public init() {}

    public enum Failure: Error, Equatable, Sendable {
        case chainCountNotUsable(UInt64)
    }

    /// A count at or above this is a bad RPC answer; `next + 1` on a maximal value would trap.
    public static let implausibleNonce: UInt64 = 1 << 48

    public func reserve(for address: EthereumAddress, chainCount: UInt64) throws -> UInt64 {
        guard chainCount < Self.implausibleNonce else {
            throw Failure.chainCountNotUsable(chainCount)
        }
        let key = address.checksummed
        let next = max(chainCount, reserved[key] ?? 0)
        reserved[key] = next + 1
        return next
    }

    public func release(for address: EthereumAddress, nonce: UInt64) {
        guard nonce < UInt64.max else { return }
        let key = address.checksummed
        if reserved[key] == nonce + 1 { reserved[key] = nonce }
    }

    public func forget(_ address: EthereumAddress) {
        reserved.removeValue(forKey: address.checksummed)
    }
}
