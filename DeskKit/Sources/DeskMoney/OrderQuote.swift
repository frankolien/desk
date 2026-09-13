import Foundation

/// Everything the user is shown before Face ID is asked for.
///
/// The product's third principle is that the number comes before the signature: size,
/// price, leverage, fee and liquidation price, in AUSD, on screen before any ceremony.
/// Assembling them in one value means a screen cannot render four of the five and quietly
/// omit the one that matters.
public struct OrderQuote: Sendable, Hashable {
    public let side: Side
    public let size: Size
    /// The price the estimate was struck at: the mark for a market order, the limit for
    /// a limit order.
    public let price: Price
    public let leverageHundredths: Int
    public let notional: Money
    /// Collateral allocated to the position.
    public let margin: Money
    public let fee: Money
    /// What actually leaves the collateral balance. The number to check affordability
    /// against, and the one a user is surprised by if only `margin` is shown.
    public let total: Money
    public let liquidationPrice: Price
    /// How far the price may move against the position before liquidation, in micros of
    /// a fraction. At BTC's 15x ceiling with 4% maintenance this is 2.67%, which the
    /// ticket has to make impossible to miss.
    public let liquidationDistanceMicros: Int
    public let pricedAt: ContinuousClock.Instant

    public enum Failure: Error, Equatable, Sendable {
        case sizeMustBePositive
        case priceMustBePositive
        case scaleMismatch
        case leverageOutOfRange(Int, max: Int)
        case leverageLeavesNoBuffer(leverageHundredths: Int, maintenanceMarginFraction: Int)
        case arithmeticFailed
    }

    /// Apple Pay re-asks for intent after sixty seconds, for the same reason: an estimate
    /// the user has stopped looking at is not an estimate they agreed to.
    public static let window: Duration = .seconds(60)

    public func age(at instant: ContinuousClock.Instant = ContinuousClock.now) -> Duration {
        pricedAt.duration(to: instant)
    }

    /// A quote past the window is re-priced before it is sent, never sent as it stands.
    public func hasExpired(at instant: ContinuousClock.Instant = ContinuousClock.now) -> Bool {
        age(at: instant) >= Self.window
    }

    public func isAffordable(freeCollateral: Money) -> Bool {
        total.raw <= freeCollateral.raw
    }

    public static func quote(
        side: Side,
        size: Size,
        price: Price,
        leverageHundredths: Int,
        feeMicros: Int64,
        initialMarginFraction: Int,
        maintenanceMarginFraction: Int,
        pricedAt: ContinuousClock.Instant = ContinuousClock.now
    ) throws -> OrderQuote {
        guard size.raw > 0 else { throw Failure.sizeMustBePositive }
        guard price.raw > 0 else { throw Failure.priceMustBePositive }
        guard leverageHundredths >= 100, leverageHundredths <= initialMarginFraction else {
            throw Failure.leverageOutOfRange(leverageHundredths, max: initialMarginFraction)
        }
        guard let distance = Margin.liquidationDistanceMicros(
            leverageHundredths: leverageHundredths,
            maintenanceMarginFraction: maintenanceMarginFraction)
        else {
            throw Failure.leverageLeavesNoBuffer(
                leverageHundredths: leverageHundredths,
                maintenanceMarginFraction: maintenanceMarginFraction)
        }

        guard let notional = Money.notional(price: price, size: size, rounding: .awayFromZero),
              let margin = Margin.initialMargin(notional: notional, leverageHundredths: leverageHundredths),
              let fee = notional.fee(rateInMicros: feeMicros)
        else { throw Failure.arithmeticFailed }

        guard let total = Money(raw: margin.raw + fee.raw) else { throw Failure.arithmeticFailed }

        // Whether the taker fee comes out of the position's own collateral or out of free
        // collateral is not something the venue documents, and it moves the liquidation
        // price. Backing the position with `margin - fee` is the conservative reading: if
        // the fee is in fact taken elsewhere, the real liquidation sits further away than
        // this, and the screen has understated the headroom rather than overstated it.
        let backing = Money(raw: margin.raw - fee.raw) ?? .zero
        guard let liquidation = Margin.liquidationPrice(
            entry: price, size: size, collateral: backing,
            maintenanceMarginFraction: maintenanceMarginFraction, side: side)
        else { throw Failure.arithmeticFailed }

        return OrderQuote(
            side: side, size: size, price: price, leverageHundredths: leverageHundredths,
            notional: notional, margin: margin, fee: fee, total: total,
            liquidationPrice: liquidation, liquidationDistanceMicros: distance,
            pricedAt: pricedAt)
    }
}
