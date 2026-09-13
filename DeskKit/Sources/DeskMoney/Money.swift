/// An amount of collateral, in AUSD. The unit every figure on every screen is in.
public struct Money: Sendable, Hashable, Comparable {
    /// Asserted against `pub/context` at launch rather than trusted.
    public static let decimals: UInt8 = 6

    /// A trillion AUSD, against a token whose supply is under 310 million. The headroom
    /// below `Int64.max` is what makes the operators below total.
    public static let maxRaw: Int64 = 1_000_000_000_000_000_000

    public let raw: Int64

    public init?(raw: Int64) {
        guard raw.magnitude <= UInt64(Money.maxRaw) else { return nil }
        self.raw = raw
    }

    init(unchecked raw: Int64) { self.raw = raw }

    public static let zero = Money(unchecked: 0)

    public var isZero: Bool { raw == 0 }
    public var isNegative: Bool { raw < 0 }

    public static func < (lhs: Money, rhs: Money) -> Bool { lhs.raw < rhs.raw }

    public static func + (lhs: Money, rhs: Money) -> Money { Money(unchecked: lhs.raw + rhs.raw) }
    public static func - (lhs: Money, rhs: Money) -> Money { Money(unchecked: lhs.raw - rhs.raw) }
    public static prefix func - (value: Money) -> Money { Money(unchecked: -value.raw) }

    public var magnitude: Money { Money(unchecked: raw < 0 ? -raw : raw) }
}

// MARK: - The product that must not be got wrong

extension Money {
    /// A function rather than a multiplication because `price.raw * size.raw` is only
    /// the answer when the decimals sum to AUSD's six — true for testnet BTC at 1 and
    /// 5, out by a factor of ten for mainnet ETH at 2 and 3.
    ///
    ///     raw = price.raw * size.raw / 10^(priceDecimals + sizeDecimals - 6)
    public static func notional(price: Price, size: Size, rounding: Rounding) -> Money? {
        let (product, productOverflowed) = Int128(price.raw).multipliedReportingOverflow(by: Int128(size.raw))
        guard !productOverflowed else { return nil }

        let exponent = Int(price.decimals) + Int(size.decimals) - Int(Money.decimals)

        let scaled: Int128
        if exponent > 0 {
            guard let divisor = Pow10.value(exponent) else { return nil }
            scaled = divide(product, by: divisor, rounding: rounding)
        } else if exponent < 0 {
            guard let factor = Pow10.value(-exponent) else { return nil }
            let (widened, overflowed) = product.multipliedReportingOverflow(by: factor)
            guard !overflowed else { return nil }
            scaled = widened
        } else {
            scaled = product
        }
        guard let fitted = Int64(exactly: scaled) else { return nil }
        return Money(raw: fitted)
    }

    /// Rate is in micros, not basis points: testnet taker 345 is 3.45 bps.
    ///
    /// A fee is a cost whichever side you are on, so it is taken on the magnitude and
    /// always rounded away from zero. A ceiling on a signed notional would understate
    /// the fee on a short.
    public func fee(rateInMicros: Int64) -> Money? {
        guard rateInMicros >= 0, rateInMicros <= 1_000_000 else { return nil }
        guard let divisor = Pow10.value(6) else { return nil }
        let magnitude = Int128(raw.magnitude)
        let (product, overflowed) = magnitude.multipliedReportingOverflow(by: Int128(rateInMicros))
        guard !overflowed else { return nil }
        let scaled = divide(product, by: divisor, rounding: .awayFromZero)
        guard let fitted = Int64(exactly: scaled) else { return nil }
        return Money(raw: fitted)
    }
}

// MARK: - Text

extension Money {
    public var text: String { DecimalText.render(raw: raw, decimals: Money.decimals) }

    /// Truncates by default: an entered amount must never grow.
    public init?(text: String, rounding: Rounding = .towardZero) {
        guard let raw = DecimalText.parse(text, decimals: Money.decimals, rounding: rounding)
        else { return nil }
        self.init(raw: raw)
    }

    /// Separators are parameters rather than locale lookups so this module stays free
    /// of Foundation. Truncates, so a gain is never rounded up into something it is not.
    public func display(
        fractionDigits: UInt8 = 2,
        rounding: Rounding = .towardZero,
        grouping: String = ",",
        point: String = "."
    ) -> String {
        let rendered = DecimalText.render(
            raw: raw, decimals: Money.decimals, fractionDigits: fractionDigits, rounding: rounding)
        return DecimalText.group(rendered, every: 3, with: grouping, point: point)
    }
}
