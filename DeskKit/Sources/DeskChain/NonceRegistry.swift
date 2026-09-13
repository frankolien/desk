import DeskAuth
import Foundation

/// Local nonce tracking, because Monad's `pending` tag equals `latest`.
///
/// An in-flight transaction does not bump `eth_getTransactionCount`, and the opening
/// sequence sends three back to back. Without this the second collides with the first.
public actor NonceRegistry {
    private var reserved: [String: UInt64] = [:]

    public init() {}

    public enum Failure: Error, Equatable, Sendable {
        case chainCountNotUsable(UInt64)
    }

    /// An account cannot plausibly have sent this many transactions, so a count at or
    /// above it is a bad RPC answer. `chainCount` is decoded from whatever node the app
    /// was pointed at, and `next + 1` on a maximal value traps the process rather than
    /// failing.
    public static let implausibleNonce: UInt64 = 1 << 48

    /// The next nonce to use, never going backwards from what has already been handed
    /// out for this address.
    public func reserve(for address: EthereumAddress, chainCount: UInt64) throws -> UInt64 {
        guard chainCount < Self.implausibleNonce else {
            throw Failure.chainCountNotUsable(chainCount)
        }
        let key = address.checksummed
        let next = max(chainCount, reserved[key] ?? 0)
        reserved[key] = next + 1
        return next
    }

    /// A send that never reached the mempool frees its nonce for the next attempt.
    public func release(for address: EthereumAddress, nonce: UInt64) {
        guard nonce < UInt64.max else { return }
        let key = address.checksummed
        if reserved[key] == nonce + 1 { reserved[key] = nonce }
    }

    public func forget(_ address: EthereumAddress) {
        reserved.removeValue(forKey: address.checksummed)
    }
}
