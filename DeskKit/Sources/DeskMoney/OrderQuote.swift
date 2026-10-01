import Foundation

public struct OrderQuote: Sendable, Hashable {
    public let side: Side
    public let size: Size
    public let price: Price
    public let leverageHundredths: Int
    public let notional: Money
    public let margin: Money
    public let fee: Money
    /// Margin plus fee: what actually leaves the balance, so affordability is checked against it.
    public let total: Money
    public let liquidationPrice: Price
    /// How far the price may move against the position before liquidation, in micros of
    /// a fraction.
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

        // The venue does not document where the taker fee comes from; `margin - fee` is the
        // conservative reading, understating liquidation headroom rather than overstating it.
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
