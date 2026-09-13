enum DecimalText {

    /// Bytes, not `Character`s: a grapheme cluster like the keycap emoji "5\u{FE0F}\u{20E3}"
    /// satisfies `>= "0" && <= "9"` while having no single ASCII value behind it.
    static func parse(_ text: String, decimals: UInt8, rounding: Rounding) -> Int64? {
        let bytes = Array(text.utf8)
        var index = 0
        var end = bytes.count
        while index < end, isASCIISpace(bytes[index]) { index += 1 }
        while end > index, isASCIISpace(bytes[end - 1]) { end -= 1 }
        guard index < end else { return nil }

        var isNegative = false
        if bytes[index] == UInt8(ascii: "-") { isNegative = true; index += 1 }
        else if bytes[index] == UInt8(ascii: "+") { index += 1 }

        let integerStart = index
        while index < end, isASCIIDigit(bytes[index]) { index += 1 }
        let integerEnd = index

        var fractionStart = index
        var fractionEnd = index
        if index < end, bytes[index] == UInt8(ascii: ".") {
            index += 1
            fractionStart = index
            while index < end, isASCIIDigit(bytes[index]) { index += 1 }
            fractionEnd = index
        }

        guard index == end else { return nil }
        guard integerEnd > integerStart || fractionEnd > fractionStart else { return nil }

        // Leading zeros must not consume the width budget: a zero-padded venue field
        // is still a small number.
        var significantStart = integerStart
        while significantStart < integerEnd, bytes[significantStart] == UInt8(ascii: "0") {
            significantStart += 1
        }

        let scale = Int(decimals)
        guard let scaleFactor = Pow10.value(scale),
              (integerEnd - significantStart) + scale <= Pow10.maxTableExponent
        else { return nil }

        var magnitude: Int128 = 0
        for position in significantStart..<integerEnd {
            magnitude = magnitude * 10 + Int128(bytes[position] - 48)
        }
        magnitude *= scaleFactor

        // Every rounding case is directional, so digits past the scale only need
        // testing for being nonzero, never comparing against a midpoint.
        var hasRemainder = false
        for (offset, position) in (fractionStart..<fractionEnd).enumerated() {
            let digit = Int128(bytes[position] - 48)
            if offset < scale {
                guard let place = Pow10.value(scale - offset - 1) else { return nil }
                magnitude += digit * place
            } else if digit != 0 {
                hasRemainder = true
                break
            }
        }

        var value = isNegative ? -magnitude : magnitude
        if hasRemainder {
            switch rounding {
            case .towardZero: break
            case .awayFromZero: value += isNegative ? -1 : 1
            case .floor: if isNegative { value -= 1 }
            case .ceiling: if !isNegative { value += 1 }
            }
        }
        return Int64(exactly: value)
    }

    static func render(raw: Int64, decimals: UInt8) -> String {
        let scale = Int(decimals)
        // `abs(Int64.min)` traps; `.magnitude` is a `UInt64` and is exact. Do not
        // "simplify" this to `abs` or `-raw`.
        var digits = String(raw.magnitude)
        if scale == 0 { return raw < 0 ? "-" + digits : digits }
        if digits.count <= scale {
            digits = String(repeating: "0", count: scale - digits.count + 1) + digits
        }
        let splitIndex = digits.index(digits.endIndex, offsetBy: -scale)
        return (raw < 0 ? "-" : "") + digits[..<splitIndex] + "." + digits[splitIndex...]
    }

    /// Never routes through `parse`: re-parsing exact text at a wider scale needs more
    /// room than the value itself, which is how a million dollars asked for twelve
    /// decimal places came back as zero.
    static func render(
        raw: Int64,
        decimals: UInt8,
        fractionDigits: UInt8,
        rounding: Rounding
    ) -> String {
        if fractionDigits >= decimals {
            let exact = render(raw: raw, decimals: decimals)
            let padding = String(repeating: "0", count: Int(fractionDigits) - Int(decimals))
            if decimals == 0 && fractionDigits > 0 { return exact + "." + padding }
            return exact + padding
        }
        let drop = Int(decimals) - Int(fractionDigits)
        guard let divisor = Pow10.value(drop) else { return render(raw: raw, decimals: decimals) }
        let reduced = Int64(truncatingIfNeeded: divide(Int128(raw), by: divisor, rounding: rounding))
        return render(raw: reduced, decimals: fractionDigits)
    }

    /// Insert a separator into the integer part of an already-rendered decimal string.
    static func group(_ rendered: String, every stride: Int, with separator: String, point: String) -> String {
        var body = Substring(rendered)
        var sign = ""
        if body.first == "-" { sign = "-"; body = body.dropFirst() }

        let whole: Substring
        let fraction: Substring?
        if let dot = body.firstIndex(of: ".") {
            whole = body[..<dot]
            fraction = body[body.index(after: dot)...]
        } else {
            whole = body
            fraction = nil
        }
        var grouped = ""
        for (offset, digit) in whole.enumerated() {
            if offset > 0 && (whole.count - offset) % stride == 0 { grouped += separator }
            grouped.append(digit)
        }
        if let fraction { return sign + grouped + point + fraction }
        return sign + grouped
    }

    @inline(__always)
    private static func isASCIIDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    @inline(__always)
    private static func isASCIISpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
