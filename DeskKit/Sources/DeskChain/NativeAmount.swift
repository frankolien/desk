import Foundation

/// An amount of the chain's own token — MON, for gas.
///
/// Deliberately not `Money`. AUSD is six decimals and MON is eighteen, and the two
/// differ by a factor of a trillion: a MON balance put through `Money` would render a
/// gas balance of 0.19 as 190,000,000,000. Separate types make that mistake fail to
/// compile rather than fail on screen.
///
/// `Int128` rather than `Int64` because eighteen decimals outgrows a `UInt64` at about
/// eighteen whole units — a wallet holding twenty MON would overflow. `Quantity.uint64`
/// throws for exactly this reason, which is why this reads the bytes itself.
public struct NativeAmount: Sendable, Hashable, Comparable {
    public static let decimals: UInt8 = 18

    /// Monad's total supply is on the order of 1e29 at this scale, comfortably inside
    /// `Int128`. The ceiling exists so a malformed word cannot produce a negative or
    /// wrapped balance.
    /// Written as digits rather than as `Int128(1e30)`: that spelling goes through a
    /// `Double`, whose 53-bit mantissa cannot hold 10^30 exactly, so the ceiling would be
    /// a rounded number nobody chose.
    public static let maxRaw: Int128 = 1_000_000_000_000_000_000_000_000_000_000

    public let raw: Int128

    public init?(raw: Int128) {
        guard raw >= 0, raw <= NativeAmount.maxRaw else { return nil }
        self.raw = raw
    }

    public static let zero = NativeAmount(unchecked: 0)

    private init(unchecked raw: Int128) { self.raw = raw }

    public var isZero: Bool { raw == 0 }

    /// A typed amount such as `1.5`. Nil for anything that is not plain digits with at
    /// most eighteen places, rather than a rounded guess at what was meant.
    public init?(decimalText text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              let whole = parts.first, !whole.isEmpty || parts.count == 2,
              whole.allSatisfy(\.isASCIIDigit) else { return nil }
        let fraction = parts.count == 2 ? parts[1] : ""
        guard fraction.count <= Int(NativeAmount.decimals), fraction.allSatisfy(\.isASCIIDigit),
              !(whole.isEmpty && fraction.isEmpty) else { return nil }
        let digits = String(whole) + fraction + String(repeating: "0", count: Int(NativeAmount.decimals) - fraction.count)
        var value: Int128 = 0
        for character in digits {
            let (shifted, overflow) = value.multipliedReportingOverflow(by: 10)
            guard !overflow else { return nil }
            value = shifted + Int128(character.wholeNumberValue!)
            guard value <= NativeAmount.maxRaw else { return nil }
        }
        self.init(unchecked: value)
    }

    /// Wei as a decimal string, the form quote APIs and JSON carry without precision loss.
    public var weiText: String { String(describing: raw) }

    /// Big-endian with leading zeros stripped, the shape a transaction's value takes.
    public var bigEndianBytes: Data {
        var bytes: [UInt8] = []
        var rest = raw
        while rest > 0 {
            bytes.insert(UInt8(rest & 0xff), at: 0)
            rest >>= 8
        }
        return Data(bytes)
    }

    public static func < (lhs: NativeAmount, rhs: NativeAmount) -> Bool { lhs.raw < rhs.raw }

    /// What `eth_getBalance` returns: a big-endian quantity, already stripped of leading
    /// zeros by the transport.
    ///
    /// A value too large for the type is clamped rather than wrapped. Wrapping would turn
    /// an absurd balance into a plausible small one, and a plausible wrong number is worse
    /// than an obviously wrong one — the user would act on it.
    public init(bigEndian bytes: Data) {
        guard !bytes.isEmpty else { self = .zero; return }
        var value: Int128 = 0
        for byte in bytes {
            let (shifted, overflowShift) = value.multipliedReportingOverflow(by: 256)
            guard !overflowShift else { self = NativeAmount(unchecked: NativeAmount.maxRaw); return }
            let (added, overflowAdd) = shifted.addingReportingOverflow(Int128(byte))
            guard !overflowAdd, added <= NativeAmount.maxRaw else {
                self = NativeAmount(unchecked: NativeAmount.maxRaw)
                return
            }
            value = added
        }
        self = NativeAmount(unchecked: value)
    }

    /// Truncates toward zero, never rounds up. A gas balance rounded up to the amount a
    /// transaction needs is a transaction that fails after the user was told it would not.
    public func display(fractionDigits: UInt8 = 4, grouping: String = ",", point: String = ".") -> String {
        let scale = NativeAmount.power(10, Int(NativeAmount.decimals))
        let whole = raw / scale
        var fraction = raw % scale

        var digits = ""
        if fractionDigits > 0 {
            // Take the leading `fractionDigits` of the eighteen, by dividing the rest away.
            let drop = Int(NativeAmount.decimals) - Int(fractionDigits)
            fraction /= NativeAmount.power(10, drop)
            digits = String(describing: fraction)
            if digits.count < Int(fractionDigits) {
                digits = String(repeating: "0", count: Int(fractionDigits) - digits.count) + digits
            }
        }

        let integer = DecimalGrouping.group(String(describing: whole), every: 3, with: grouping)
        return fractionDigits > 0 ? integer + point + digits : integer
    }

    private static func power(_ base: Int128, _ exponent: Int) -> Int128 {
        var result: Int128 = 1
        for _ in 0..<exponent { result *= base }
        return result
    }
}

/// Digit grouping, kept here rather than reaching into `DeskMoney`'s internals.
enum DecimalGrouping {
    static func group(_ digits: String, every stride: Int, with separator: String) -> String {
        guard digits.count > stride, !separator.isEmpty else { return digits }
        var out = ""
        for (offset, character) in digits.enumerated() {
            if offset > 0, (digits.count - offset) % stride == 0 { out += separator }
            out.append(character)
        }
        return out
    }
}

extension Character {
    /// `isNumber` also accepts other scripts' digits and fractions, which are not wei.
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
