import DeskMoney
import Foundation

extension OrderQuote {
    public static func forMarket(
        _ market: Market,
        side: Side,
        size: Size,
        price: Price,
        leverageHundredths: Int,
        isMaker: Bool = false,
        pricedAt: ContinuousClock.Instant = ContinuousClock.now
    ) throws -> OrderQuote {
        guard price.decimals == market.config.priceDecimals,
              size.decimals == market.config.sizeDecimals
        else { throw OrderQuote.Failure.scaleMismatch }
        return try quote(
            side: side, size: size, price: price, leverageHundredths: leverageHundredths,
            // A post-only limit pays maker; everything else pays taker. Maker on a crossing
            // order would understate the cost nearly eightfold on BTC.
            feeMicros: isMaker ? market.config.makerFeeMicros : market.config.takerFeeMicros,
            initialMarginFraction: market.config.initialMarginFraction,
            maintenanceMarginFraction: market.config.maintenanceMarginFraction,
            pricedAt: pricedAt)
    }
}
