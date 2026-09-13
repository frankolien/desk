
public enum Side: Sendable, Hashable {
    case long, short
}

/// Position mathematics, in scaled integers throughout.
///
/// Perpl computes maintenance margin against the **entry** price, not the mark. Its own
/// prose uses the mark-based form and therefore contradicts its contract; the contract
/// and its published worked example agree with each other, so they win. On a $100,000
/// BTC long at 10x with 4% maintenance the two differ by $250.
public enum Margin {
    /// `P_liq = E(1 + mm) - C/S` for a long, `E(1 - mm) + C/S` for a short.
    ///
    /// Rounded against the trader: up for a long and down for a short, so the screen
    /// never shows more headroom than exists.
    public static func liquidationPrice(
        entry: Price,
        size: Size,
        collateral: Money,
        maintenanceMarginFraction: Int,
        side: Side
    ) -> Price? {
        guard maintenanceMarginFraction > 0, size.raw > 0 else { return nil }

        // E * mm, where mm = 100 / maintenanceMarginFraction.
        let marginTerm = divide(Int128(entry.raw) * 100,
                                by: Int128(maintenanceMarginFraction),
                                rounding: side == .long ? .ceiling : .towardZero)

        // C / S restated at the price scale: C_raw * 10^(sd + pd - 6) / S_raw.
        let exponent = Int(size.decimals) + Int(entry.decimals) - Int(Money.decimals)
        var numerator = Int128(collateral.raw)
        if exponent > 0 {
            guard let factor = Pow10.value(exponent) else { return nil }
            let (widened, overflowed) = numerator.multipliedReportingOverflow(by: factor)
            guard !overflowed else { return nil }
            numerator = widened
        } else if exponent < 0 {
            guard let divisor = Pow10.value(-exponent) else { return nil }
            numerator = divide(numerator, by: divisor, rounding: .towardZero)
        }
        let collateralTerm = divide(numerator,
                                    by: Int128(size.raw),
                                    rounding: side == .long ? .towardZero : .ceiling)

        let raw: Int128 = side == .long
            ? Int128(entry.raw) + marginTerm - collateralTerm
            : Int128(entry.raw) - marginTerm + collateralTerm
        guard raw > 0, let fitted = Int64(exactly: raw) else { return nil }
        return Price(raw: fitted, decimals: entry.decimals)
    }

    /// How far price must move, as a fraction of entry, in millionths.
    ///
    /// Collapses to `1/L - mm` because `C/(S*E)` is exactly `1/L`. At BTC's 15x ceiling
    /// with 4% maintenance that is 2.67% — the number the ticket must make impossible
    /// to miss.
    public static func liquidationDistanceMicros(
        leverageHundredths: Int,
        maintenanceMarginFraction: Int
    ) -> Int? {
        guard leverageHundredths > 0, maintenanceMarginFraction > 0 else { return nil }
        let inverseLeverage = 100_000_000 / leverageHundredths
        let maintenance = 100_000_000 / maintenanceMarginFraction
        let distance = inverseLeverage - maintenance
        return distance > 0 ? distance : nil
    }

    /// Collateral required to open `notional` at this leverage, rounded up.
    public static func initialMargin(notional: Money, leverageHundredths: Int) -> Money? {
        guard leverageHundredths > 0 else { return nil }
        let raw = divide(Int128(notional.raw.magnitude) * 100,
                         by: Int128(leverageHundredths),
                         rounding: .awayFromZero)
        guard let fitted = Int64(exactly: raw) else { return nil }
        return Money(raw: fitted)
    }

    /// Unrealised profit, against the mark rather than the last trade.
    public static func unrealisedPnL(
        entry: Price,
        mark: Price,
        size: Size,
        side: Side
    ) -> Money? {
        guard entry.decimals == mark.decimals else { return nil }
        let difference = side == .long ? mark - entry : entry - mark
        return Money.notional(price: difference, size: size, rounding: .towardZero)
    }
}
