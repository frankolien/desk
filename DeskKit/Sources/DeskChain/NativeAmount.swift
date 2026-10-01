import Foundation

/// Deliberately not `Money`: AUSD is six decimals and MON eighteen. `Int128` because eighteen
/// decimals outgrow a `UInt64` at about eighteen MON.
public struct NativeAmount: Sendable, Hashable, Comparable {
    public static let decimals: UInt8 = 18

    /// Guards against a malformed word. Written as digits: `Int128(1e30)` goes through a `Double`,
    /// which cannot hold 10^30 exactly.
    public static let maxRaw: Int128 = 1_000_000_000_000_000_000_000_000_000_000

    public let raw: Int128

    public init?(raw: Int128) {
        guard raw >= 0, raw <= NativeAmount.maxRaw else { return nil }
        self.raw = raw
    }

    public static let zero = NativeAmount(unchecked: 0)

    private init(unchecked raw: Int128) { self.raw = raw }

    public var isZero: Bool { raw == 0 }

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

    public var weiText: String { String(describing: raw) }

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

    /// Clamped rather than wrapped: wrapping would turn an absurd balance into a plausible small one.
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

    /// Truncates toward zero: rounding a gas balance up would promise a transaction it cannot pay for.
    public func display(fractionDigits: UInt8 = 4, grouping: String = ",", point: String = ".") -> String {
        let scale = NativeAmount.power(10, Int(NativeAmount.decimals))
        let whole = raw / scale
        var fraction = raw % scale

        var digits = ""
        if fractionDigits > 0 {
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
