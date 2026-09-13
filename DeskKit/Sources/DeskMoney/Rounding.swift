public enum Rounding: Sendable, Hashable, CaseIterable {
    case towardZero
    case awayFromZero
    /// Toward negative infinity. Differs from `towardZero` below zero, which is how
    /// `NSDecimalRound(.down)` grows a short position.
    case floor
    case ceiling
}

@inlinable
func divide(_ dividend: Int128, by divisor: Int128, rounding: Rounding) -> Int128 {
    precondition(divisor > 0, "divisor must be positive")
    let quotient = dividend / divisor
    let remainder = dividend % divisor
    if remainder == 0 { return quotient }

    switch rounding {
    case .towardZero:
        return quotient
    case .awayFromZero:
        return dividend > 0 ? quotient + 1 : quotient - 1
    case .floor:
        return dividend > 0 ? quotient : quotient - 1
    case .ceiling:
        return dividend > 0 ? quotient + 1 : quotient
    }
}
