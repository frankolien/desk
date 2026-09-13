import DeskMoney
import Foundation

/// Everything the position screen shows, derived once from one tick.
///
/// The reason this is a type rather than a handful of computed properties on a view: mark,
/// unrealised PnL and liquidation distance all descend from the same price. Derived
/// separately in a view they can be computed from two different ticks a frame apart, and
/// the screen then shows a PnL that does not match the mark above it. Deriving them
/// together means they are either all from this tick or all from the last one, which is
/// what lets the screen dim them as a group when the price goes stale.
public struct PositionFigures: Sendable, Hashable {
    public let side: Side
    public let leverageHundredths: Int
    public let entry: Price
    public let mark: Price
    public let size: Size
    public let collateral: Money
    public let unrealisedPnL: Money
    /// Profit as a fraction of the collateral backing this position, in micros.
    ///
    /// The denominator is named because there is no standard one — Hyperliquid divides by
    /// account equity, Binance by entry margin, OKX by position margin, and the three are
    /// not interchangeable. This is margin, and the screen must say so.
    public let returnOnMarginMicros: Int
    public let liquidationPrice: Price?
    /// How far the mark may move from *here* before liquidation, in micros.
    ///
    /// Distinct from `Margin.liquidationDistanceMicros`, which answers the same question
    /// at the moment of entry and never changes. This one shrinks as a position goes
    /// against the user, which is the number that actually matters once they are in.
    public let liquidationDistanceMicros: Int?
    /// Funding paid or received since entry, from the accumulator difference rather than
    /// from summing anything client-side.
    public let fundingSinceEntry: Money?

    public var isProfit: Bool { !unrealisedPnL.isNegative && !unrealisedPnL.isZero }

    /// Nil when the venue's figures cannot be scaled into this app's types — a size of
    /// zero, decimals that do not fit, a price that overflows. A screen with no figures
    /// renders as unavailable, which is correct: a fabricated position is worse than
    /// none.
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

        // Against the collateral committed here. Guarded, because a position the venue
        // reports with zero collateral would otherwise divide by nothing.
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

        // Measured from the mark, not from entry: once a position is open, what the user
        // needs is how much room is left, not how much there was.
        if let liquidation, mark.raw > 0 {
            let gap = Int128(mark.raw) - Int128(liquidation.raw)
            let magnitude = gap < 0 ? -gap : gap
            // A mark already past the liquidation price means no room at all rather than
            // a negative amount of it.
            let isPastLiquidation = side == .long ? mark.raw <= liquidation.raw : mark.raw >= liquidation.raw
            liquidationDistanceMicros = isPastLiquidation
                ? 0
                : Int(clamping: magnitude * 1_000_000 / Int128(mark.raw))
        } else {
            liquidationDistanceMicros = nil
        }

        // Funding settles virtually through an accumulator, so what is owed is the
        // difference of two sums rather than anything accumulated on this device.
        //
        // The accumulator is carried at the price scale, so the delta multiplied by size
        // lands at the collateral scale exactly as a notional does. It is not a price,
        // and it is only spelled as one here because that is the scale it arrives at.
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
