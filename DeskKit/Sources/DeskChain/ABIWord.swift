import Foundation

/// Thirty-two byte words, big-endian, as EIP-712 and the ABI encode them.
enum ABIWord {
    enum Failure: Error, Equatable, Sendable {
        case notAnInteger(String)
        case doesNotFitIn32Bytes(String)
        case notHex(String)
        case oddLengthHex(String)
        case wrongByteCount(expected: Int, got: Int)
        case outOfRange(String, type: String)
    }

    /// Strict: `0x` required, even length, every character a hex digit.
    ///
    /// Odd length is refused rather than truncated. Dropping the trailing nibble made
    /// `0xabc` and `0xab` hash alike, which is two different payloads under one
    /// signature; left-padding instead would match viem but silently reinterpret a
    /// typo, and a venue that means `0x0abc` can say so.
    static func hexBytes(_ text: String) throws -> Data {
        let characters = Array(text.utf8)
        guard characters.count >= 2, characters[0] == UInt8(ascii: "0"),
              characters[1] | 0x20 == UInt8(ascii: "x")
        else { throw Failure.notHex(text) }

        let digits = characters.dropFirst(2)
        guard digits.count % 2 == 0 else { throw Failure.oddLengthHex(text) }

        var bytes = Data()
        bytes.reserveCapacity(digits.count / 2)
        var index = digits.startIndex
        while index < digits.endIndex {
            guard let high = nibble(digits[index]), let low = nibble(digits[index + 1]) else {
                throw Failure.notHex(text)
            }
            bytes.append(high << 4 | low)
            index += 2
        }
        return bytes
    }

    /// A hex digit's value, by byte. `UInt8(_:radix:)` cannot be used for this: it
    /// honours a sign prefix, so `"+f"` parses as 15 and a forty-character run of
    /// `+1+2+3…` becomes a perfectly valid-looking address inside a signed digest.
    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    /// Accepts decimal or 0x-hex, range-checked against the declared width.
    ///
    /// Perpl sends `chainId` as `"0x279f"` and `time` as `"0x1a09a29c91c"`, both typed
    /// as integers. Hashing either as its characters rather than its value produces a
    /// digest the gateway rejects — and viem does exactly that silently rather than
    /// throwing, which is what makes this worth its own function.
    static func uint(_ text: String, bits: Int = 256) throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw Failure.notAnInteger(text) }

        let word: Data
        if trimmed.count >= 2, trimmed.utf8.first == UInt8(ascii: "0"),
           Array(trimmed.utf8)[1] | 0x20 == UInt8(ascii: "x") {
            word = try fromHex(trimmed, original: text)
        } else {
            word = try fromDecimal(trimmed, original: text)
        }
        guard fits(word, bits: bits, signed: false) else {
            throw Failure.outOfRange(text, type: "uint\(bits)")
        }
        return word
    }

    /// Two's complement, sign-extended across the whole word, as the ABI requires.
    static func int(_ text: String, bits: Int = 256) throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == "-" else {
            let word = try uint(trimmed, bits: 256)
            guard fits(word, bits: bits - 1, signed: false) else {
                throw Failure.outOfRange(text, type: "int\(bits)")
            }
            return word
        }

        let magnitude = try uint(String(trimmed.dropFirst()), bits: 256)
        // The negative end reaches one further than the positive one, so the bound is
        // checked on the magnitude before it is negated, not on the result.
        guard fits(magnitude, bits: bits - 1, signed: false) || isExactly(magnitude, bit: bits - 1)
        else { throw Failure.outOfRange(text, type: "int\(bits)") }
        return negated(magnitude)
    }

    static func address(_ text: String) throws -> Data {
        let bytes = try hexBytes(text)
        guard bytes.count == 20 else { throw Failure.wrongByteCount(expected: 20, got: bytes.count) }
        var word = Data(repeating: 0, count: 32)
        word.replaceSubrange(12..<32, with: bytes)
        return word
    }

    /// `bytesN` is right-padded, the opposite of an integer. Routing it through `uint`
    /// left-pads and produces a word that is wrong rather than an error.
    static func bytesN(_ text: String, count: Int) throws -> Data {
        let bytes = try hexBytes(text)
        guard bytes.count == count else {
            throw Failure.wrongByteCount(expected: count, got: bytes.count)
        }
        var word = Data(repeating: 0, count: 32)
        word.replaceSubrange(0..<count, with: bytes)
        return word
    }

    static func bytes32(_ text: String) throws -> Data { try bytesN(text, count: 32) }

    static func bool(_ value: Bool) -> Data {
        var word = Data(repeating: 0, count: 32)
        word[31] = value ? 1 : 0
        return word
    }

    // MARK: - Parsing

    private static func fromHex(_ trimmed: String, original: String) throws -> Data {
        var digits = Array(trimmed.utf8.dropFirst(2))
        guard !digits.isEmpty else { throw Failure.notAnInteger(original) }
        // Leading zeros are padding, not width. Counting them made a zero-padded field
        // that fits perfectly well look oversized.
        while digits.count > 1, digits[0] == UInt8(ascii: "0") { digits.removeFirst() }
        guard digits.count <= 64 else { throw Failure.doesNotFitIn32Bytes(original) }

        if digits.count % 2 == 1 { digits.insert(UInt8(ascii: "0"), at: 0) }
        var bytes = [UInt8]()
        var index = 0
        while index < digits.count {
            guard let high = nibble(digits[index]), let low = nibble(digits[index + 1]) else {
                throw Failure.notHex(original)
            }
            bytes.append(high << 4 | low)
            index += 2
        }
        var word = Data(repeating: 0, count: 32)
        word.replaceSubrange((32 - bytes.count)..<32, with: bytes)
        return word
    }

    /// Repeated multiply-accumulate over the word itself, so a full uint256 needs no
    /// big-integer type. Iterates UTF-8 bytes rather than `Character`s: `wholeNumberValue`
    /// answers for Arabic-Indic digits, fullwidth digits and superscripts alike, so `"١٠٠"`
    /// parses as a hundred and `"1²"` as twelve.
    private static func fromDecimal(_ trimmed: String, original: String) throws -> Data {
        var word = Data(repeating: 0, count: 32)
        for byte in trimmed.utf8 {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else {
                throw Failure.notAnInteger(original)
            }
            var carry = UInt32(byte - UInt8(ascii: "0"))
            for position in stride(from: 31, through: 0, by: -1) {
                let product = UInt32(word[position]) * 10 + carry
                word[position] = UInt8(product & 0xff)
                carry = product >> 8
            }
            guard carry == 0 else { throw Failure.doesNotFitIn32Bytes(original) }
        }
        return word
    }

    // MARK: - Width

    private static func fits(_ word: Data, bits: Int, signed: Bool) -> Bool {
        guard bits < 256 else { return true }
        guard bits > 0 else { return word.allSatisfy { $0 == 0 } }
        let clearedBits = 256 - bits
        let wholeBytes = clearedBits / 8
        for index in 0..<wholeBytes where word[index] != 0 { return false }
        let remainder = clearedBits % 8
        if remainder > 0, word[wholeBytes] >> (8 - UInt8(remainder)) != 0 { return false }
        return true
    }

    /// Exactly 2^bit, which is the one magnitude a signed type accepts only when negative.
    private static func isExactly(_ word: Data, bit: Int) -> Bool {
        guard bit < 256 else { return false }
        let index = 31 - bit / 8
        for position in 0..<32 where position != index && word[position] != 0 { return false }
        return word[index] == UInt8(1) << UInt8(bit % 8)
    }

    private static func negated(_ word: Data) -> Data {
        var result = Data(word.map { ~$0 })
        for position in stride(from: 31, through: 0, by: -1) {
            let (sum, carried) = result[position].addingReportingOverflow(1)
            result[position] = sum
            if !carried { break }
        }
        return result
    }
}
