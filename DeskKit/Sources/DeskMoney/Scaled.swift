/// Marks what a `Scaled` value is, so the compiler refuses to mix them.
public protocol ScaleTag: Sendable, Hashable {
    static var label: String { get }
}

public enum PriceTag: ScaleTag { public static let label = "price" }
public enum SizeTag: ScaleTag { public static let label = "size" }

public typealias Price = Scaled<PriceTag>
public typealias Size = Scaled<SizeTag>

/// An exact decimal quantity: an integer and the power of ten it is scaled by.
///
/// Decimals travel with the value because they are market data, not constants —
/// `price_decimals + size_decimals` is 6 on testnet BTC and 5 on mainnet ETH.
public struct Scaled<Tag: ScaleTag>: Sendable, Hashable {
    /// `Int64.min` is representable in the i64 fields a venue sends, and negating it
    /// traps. Bounding the boundary here is what makes the arithmetic below total.
    public static var maxRaw: Int64 { 1_000_000_000_000_000_000 }

    public let raw: Int64
    public let decimals: UInt8

    public init?(raw: Int64, decimals: UInt8) {
        guard Int(decimals) <= Pow10.maxExponent else { return nil }
        guard raw.magnitude <= UInt64(Self.maxRaw) else { return nil }
        self.raw = raw
        self.decimals = decimals
    }

    /// Results of arithmetic between checked values; bounded by `2 * maxRaw`.
    init(unchecked raw: Int64, decimals: UInt8) {
        self.raw = raw
        self.decimals = decimals
    }

    public func zeroed() -> Self { Self(unchecked: 0, decimals: decimals) }
    public var isZero: Bool { raw == 0 }
    public var isNegative: Bool { raw < 0 }
}

// MARK: - Comparison and arithmetic at a fixed scale

extension Scaled: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        precondition(lhs.decimals == rhs.decimals,
                     "cannot compare \(Tag.label) at \(lhs.decimals) and \(rhs.decimals) decimals")
        return lhs.raw < rhs.raw
    }
}

extension Scaled {
    public static func + (lhs: Self, rhs: Self) -> Self {
        precondition(lhs.decimals == rhs.decimals,
                     "cannot add \(Tag.label) at \(lhs.decimals) and \(rhs.decimals) decimals")
        return Self(unchecked: lhs.raw + rhs.raw, decimals: lhs.decimals)
    }

    public static func - (lhs: Self, rhs: Self) -> Self {
        precondition(lhs.decimals == rhs.decimals,
                     "cannot subtract \(Tag.label) at \(lhs.decimals) and \(rhs.decimals) decimals")
        return Self(unchecked: lhs.raw - rhs.raw, decimals: lhs.decimals)
    }

    public static prefix func - (value: Self) -> Self {
        Self(unchecked: -value.raw, decimals: value.decimals)
    }

    public func rescaled(to newDecimals: UInt8, rounding: Rounding) -> Self? {
        if newDecimals == decimals { return self }
        guard Int(newDecimals) <= Pow10.maxExponent else { return nil }

        let value: Int128
        if newDecimals > decimals {
            guard let factor = Pow10.value(Int(newDecimals) - Int(decimals)) else { return nil }
            let (product, overflowed) = Int128(raw).multipliedReportingOverflow(by: factor)
            guard !overflowed else { return nil }
            value = product
        } else {
            guard let divisor = Pow10.value(Int(decimals) - Int(newDecimals)) else { return nil }
            value = divide(Int128(raw), by: divisor, rounding: rounding)
        }
        guard let fitted = Int64(exactly: value) else { return nil }
        return Self(raw: fitted, decimals: newDecimals)
    }
}

// MARK: - Text, with the rounding rule chosen by the operation

extension Scaled {
    public var text: String { DecimalText.render(raw: raw, decimals: decimals) }

    public init?(text: String, decimals: UInt8, rounding: Rounding) {
        guard let raw = DecimalText.parse(text, decimals: decimals, rounding: rounding)
        else { return nil }
        self.init(raw: raw, decimals: decimals)
    }

    public func display(
        fractionDigits: UInt8,
        rounding: Rounding = .towardZero,
        grouping: String = ",",
        point: String = "."
    ) -> String {
        let rendered = DecimalText.render(
            raw: raw, decimals: decimals, fractionDigits: fractionDigits, rounding: rounding)
        return DecimalText.group(rendered, every: 3, with: grouping, point: point)
    }
}

extension Scaled where Tag == SizeTag {
    /// No rounding parameter: rounding a size up can demand margin that is not there,
    /// and `floor` grows a short. docs/04-algorithms.md section 9.
    public init?(typed text: String, decimals: UInt8) {
        self.init(text: text, decimals: decimals, rounding: .towardZero)
    }
}

extension Scaled where Tag == PriceTag {
    /// Never pays more than intended.
    public init?(buying text: String, decimals: UInt8) {
        self.init(text: text, decimals: decimals, rounding: .floor)
    }

    /// Never accepts less than intended.
    public init?(selling text: String, decimals: UInt8) {
        self.init(text: text, decimals: decimals, rounding: .ceiling)
    }
}
