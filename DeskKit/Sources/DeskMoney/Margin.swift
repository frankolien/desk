
public enum Side: Sendable, Hashable {
    case long, short
}

/// Perpl computes maintenance margin against the entry price, not the mark: its contract and
/// worked example say so, though its prose does not.
public enum Margin {
    /// `P_liq = E(1 + mm) - C/S` for a long, `E(1 - mm) + C/S` for a short, rounded against the
    /// trader so the screen never shows more headroom than exists.
    public static func liquidationPrice(
        entry: Price,
        size: Size,
        collateral: Money,
        maintenanceMarginFraction: Int,
        side: Side
    ) -> Price? {
        guard maintenanceMarginFraction > 0, size.raw > 0 else { return nil }

        // E * mm, where mm = 100 / maintenanceMarginFraction. Always rounded up.
        let marginTerm = divide(Int128(entry.raw) * 100,
                                by: Int128(maintenanceMarginFraction),
                                rounding: .ceiling)

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
        // And always down, for the same reason: subtracted for a long, added for a short.
        let collateralTerm = divide(numerator,
                                    by: Int128(size.raw),
                                    rounding: .towardZero)

        let raw: Int128 = side == .long
            ? Int128(entry.raw) + marginTerm - collateralTerm
            : Int128(entry.raw) - marginTerm + collateralTerm
        guard raw > 0, let fitted = Int64(exactly: raw) else { return nil }
        return Price(raw: fitted, decimals: entry.decimals)
    }

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

    public static func initialMargin(notional: Money, leverageHundredths: Int) -> Money? {
        guard leverageHundredths > 0 else { return nil }
        let raw = divide(Int128(notional.raw.magnitude) * 100,
                         by: Int128(leverageHundredths),
                         rounding: .awayFromZero)
        guard let fitted = Int64(exactly: raw) else { return nil }
        return Money(raw: fitted)
    }

    /// Perpl reports entry as a whole price plus `epr`, a Q16 fraction of one tick: the true entry is
    /// `entry + residue / 65_536`. Ignoring it biases every position the same way by up to a tick.
    public static func unrealisedPnL(
        entry: Price,
        residueQ16: Int,
        mark: Price,
        size: Size,
        side: Side
    ) -> Money? {
        guard entry.decimals == mark.decimals, size.raw >= 0 else { return nil }

        let scaledGap: Int128 = side == .long
            ? (Int128(mark.raw) - Int128(entry.raw)) * 65_536 - Int128(residueQ16)
            : (Int128(entry.raw) - Int128(mark.raw)) * 65_536 + Int128(residueQ16)

        let (product, overflowed) = scaledGap.multipliedReportingOverflow(by: Int128(size.raw))
        guard !overflowed else { return nil }

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
