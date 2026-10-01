import DeskMoney
import Foundation

/// Everything the position screen shows, derived together from one tick so mark, PnL and
/// liquidation distance never mix two ticks and can dim as a group when stale.
public struct PositionFigures: Sendable, Hashable {
    public let side: Side
    public let leverageHundredths: Int
    public let entry: Price
    public let mark: Price
    public let size: Size
    public let collateral: Money
    public let unrealisedPnL: Money
    /// Profit over this position's margin, in micros. Venues differ on the denominator
    /// (equity, entry margin, position margin), so the screen must say it is margin.
    public let returnOnMarginMicros: Int
    public let liquidationPrice: Price?
    public let liquidationDistanceMicros: Int?
    public let fundingSinceEntry: Money?

    public var isProfit: Bool { !unrealisedPnL.isNegative && !unrealisedPnL.isZero }

    public init?(
        position: PerplPosition,
        market: MarketConfig,
        mark: Price,
        currentFundingSum: Int64? = nil
    ) {
        guard position.sizeRaw > 0,
              let entry = Price(raw: position.entryRaw, decimals: market.priceDecimals),
              let size = Size(raw: position.sizeRaw, decimals: market.sizeDecimals),
              let collateral = Money(raw: position.collateralRaw),
              mark.decimals == market.priceDecimals
        else { return nil }

        let side = position.side
        guard let pnl = Margin.unrealisedPnL(
            entry: entry,
            residueQ16: position.entryResidue ?? 0,
            mark: mark,
            size: size,
            side: side)
        else { return nil }

        self.side = side
        self.leverageHundredths = position.leverageHundredths
        self.entry = entry
        self.mark = mark
        self.size = size
        self.collateral = collateral
        self.unrealisedPnL = pnl

        if collateral.raw > 0 {
            let ratio = Int128(pnl.raw) * 1_000_000 / Int128(collateral.raw)
            returnOnMarginMicros = Int(clamping: ratio)
        } else {
            returnOnMarginMicros = 0
        }

        let liquidation = Margin.liquidationPrice(
            entry: entry,
            size: size,
            collateral: collateral,
            maintenanceMarginFraction: market.maintenanceMarginFraction,
            side: side)
        self.liquidationPrice = liquidation

        if let liquidation, mark.raw > 0 {
            let gap = Int128(mark.raw) - Int128(liquidation.raw)
            let magnitude = gap < 0 ? -gap : gap
            let isPastLiquidation = side == .long ? mark.raw <= liquidation.raw : mark.raw >= liquidation.raw
            liquidationDistanceMicros = isPastLiquidation
                ? 0
                : Int(clamping: magnitude * 1_000_000 / Int128(mark.raw))
        } else {
            liquidationDistanceMicros = nil
        }

        // Funding is the difference of two accumulator sums. The accumulator arrives at the price
        // scale, so delta times size lands at the collateral scale like a notional; it is not a price.
        if let currentFundingSum,
           let delta = Funding.accumulatorDelta(
            entrySum: position.entryFundingSum, exitSum: currentFundingSum),
           let deltaAsScale = Price(raw: delta, decimals: market.priceDecimals),
           let notional = Money.notional(price: deltaAsScale, size: size, rounding: .towardZero) {
            // A long pays when the accumulator has risen; a short receives.
            fundingSinceEntry = side == .long ? -notional : notional
        } else {
            fundingSinceEntry = nil
        }
    }
}
