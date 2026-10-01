import Foundation

/// Monad charges the gas **limit**, not the gas used, so the limit is the bill. A
/// conventional 1.5x to 2x safety multiplier would overcharge the user.
public enum GasPolicy: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case estimateNotUsable(UInt64)
    }

    public static let marginBasisPoints: UInt64 = 10_750

    /// Below this a transaction is dropped at the mempool as `FeeTooLow`. Monad's own
    /// best-practices page still shows 50 gwei, which would be rejected.
    public static let minimumFeeWei: UInt64 = 100_000_000_000

    public static let priorityFeeWei: UInt64 = 2_000_000_000

    public static let plainTransferGas: UInt64 = 21_000

    public static let blockGasLimit: UInt64 = 150_000_000

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
