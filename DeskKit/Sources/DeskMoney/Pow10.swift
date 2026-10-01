enum Pow10 {
    static let maxExponent = 18

    /// 10^38 is the last power that fits in an `Int128`; one more traps at launch.
    static let maxTableExponent = 38

    static let table: [Int128] = {
        var values: [Int128] = [1]
        values.reserveCapacity(maxTableExponent + 1)
        for _ in 1...maxTableExponent { values.append(values[values.count - 1] * 10) }
        return values
    }()

    /// Optional rather than trapping: exponents derive from venue-supplied decimals.
    @inlinable
    static func value(_ exponent: Int) -> Int128? {
        guard exponent >= 0, exponent <= maxTableExponent else { return nil }
        return table[exponent]
    }
}
