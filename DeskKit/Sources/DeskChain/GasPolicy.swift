import Foundation

/// Monad charges the gas **limit**, not the gas used, so the limit is the bill.
///
/// A library's conventional 1.5x to 2x safety multiplier is an eighty-six percent
/// overcharge here. This type exists so no such default can reach a user.
public enum GasPolicy: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case estimateNotUsable(UInt64)
    }

    /// Monad's own published constant: 10,750 basis points.
    public static let marginBasisPoints: UInt64 = 10_750

    /// Below this a transaction is dropped at the mempool as `FeeTooLow`. Monad's own
    /// best-practices page still shows 50 gwei, which would be rejected.
    public static let minimumFeeWei: UInt64 = 100_000_000_000

    /// What the node itself suggests.
    public static let priorityFeeWei: UInt64 = 2_000_000_000

    /// A plain transfer is exactly this and takes no buffer.
    public static let plainTransferGas: UInt64 = 21_000

    /// Read from `eth_getBlockByNumber` on testnet, 13 September. A single transaction
    /// cannot exceed it, so an estimate above it is a bad answer rather than a big one.
    public static let blockGasLimit: UInt64 = 150_000_000

    /// Every input here arrives from an RPC node the app was pointed at, so each is a
    /// number someone else chose. Swift traps on overflow rather than wrapping, and a
    /// trap is a dead process, not a caught error — which is why the bounds are checked
    /// rather than assumed.
    public static func gasLimit(estimate: UInt64) throws -> UInt64 {
        guard estimate > 0, estimate <= blockGasLimit else {
            throw Failure.estimateNotUsable(estimate)
        }
        let padded = (estimate * marginBasisPoints + 9_999) / 10_000
        return max(padded, plainTransferGas)
    }

    /// A cap rather than a charge — `price = min(base + priority, maxFee)` — so headroom
    /// costs nothing. Spend caution here, never on the limit.
    public static func maxFeePerGas(baseFeeWei: UInt64) -> UInt64 {
        let doubled = baseFeeWei.multipliedReportingOverflow(by: 2)
        guard !doubled.overflow else { return UInt64.max }
        let capped = doubled.partialValue.addingReportingOverflow(priorityFeeWei)
        guard !capped.overflow else { return UInt64.max }
        return max(minimumFeeWei * 2, capped.partialValue)
    }

    // Deliberately absent: any fallback that substitutes a large limit when an estimate
    // reverts. On Monad that charges the user the whole thing. Surface the revert.
}
