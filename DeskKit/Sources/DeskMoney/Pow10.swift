enum Pow10 {
    /// Cap on a single quantity's decimals. Keeping it well below the table's ceiling
    /// is what lets the products in `Money.notional` be range-checked rather than hoped
    /// about; market decimals are single digits in practice.
    static let maxExponent = 18

    /// 10^38 is the last power that fits in an `Int128`; one more traps at launch.
    static let maxTableExponent = 38

    static let table: [Int128] = {
        var values: [Int128] = [1]
        values.reserveCapacity(maxTableExponent + 1)
        for _ in 1...maxTableExponent { values.append(values[values.count - 1] * 10) }
        return values
    }()

    /// Optional rather than trapping: every exponent here derives from venue-supplied
    /// decimals, so a venue that changes shape must make a calculation decline.
    @inlinable
    static func value(_ exponent: Int) -> Int128? {
        guard exponent >= 0, exponent <= maxTableExponent else { return nil }
        return table[exponent]
    }
}
