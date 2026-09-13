
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

    /// Unrealised profit with the venue's sub-tick entry residue applied.
    ///
    /// Perpl reports entry as a whole price plus `epr`, a Q16 fraction of one tick, so
    /// the true entry is `entry + residue / 65_536`. Ignoring the residue is the obvious
    /// shortcut and the wrong one: it does not average out, it biases every position in
    /// the same direction by up to one tick, and a bias that always leans one way reads
    /// to a user as the app being wrong rather than as rounding.
    ///
    /// Computed by multiplying through by 65,536 so the division happens once, at the
    /// end, in `Int128`. Truncating toward zero keeps the figure conservative: a profit
    /// is never rounded up and a loss is never rounded away.
    public static func unrealisedPnL(
        entry: Price,
        residueQ16: Int,
        mark: Price,
        size: Size,
        side: Side
    ) -> Money? {
        guard entry.decimals == mark.decimals, size.raw >= 0 else { return nil }

        // The gap, in sixty-five-thousand-five-hundred-and-thirty-sixths of a tick.
        let scaledGap: Int128 = side == .long
            ? (Int128(mark.raw) - Int128(entry.raw)) * 65_536 - Int128(residueQ16)
            : (Int128(entry.raw) - Int128(mark.raw)) * 65_536 + Int128(residueQ16)

        let (product, overflowed) = scaledGap.multipliedReportingOverflow(by: Int128(size.raw))
        guard !overflowed else { return nil }

        // Back to the collateral's scale: divide by 65,536 and by 10^(pd + sd - 6).
        let exponent = Int(entry.decimals) + Int(size.decimals) - Int(Money.decimals)
        var divisor = Int128(65_536)
        if exponent > 0 {
            guard let factor = Pow10.value(exponent) else { return nil }
            let (widened, tooBig) = divisor.multipliedReportingOverflow(by: factor)
            guard !tooBig else { return nil }
            divisor = widened
        } else if exponent < 0 {
            guard let factor = Pow10.value(-exponent) else { return nil }
            let (widened, tooBig) = product.multipliedReportingOverflow(by: factor)
            guard !tooBig else { return nil }
            let raw = divide(widened, by: divisor, rounding: .towardZero)
            guard let fitted = Int64(exactly: raw) else { return nil }
            return Money(raw: fitted)
        }

        let raw = divide(product, by: divisor, rounding: .towardZero)
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
