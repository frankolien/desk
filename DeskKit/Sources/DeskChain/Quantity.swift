import Foundation

/// Ethereum JSON-RPC's `QUANTITY`: hex, `0x` prefixed, no leading zeros, zero is `0x0`.
enum Quantity {
    enum Failure: Error, Equatable, Sendable {
        case notAQuantity(String)
        case tooLargeForUInt64(String)
    }

    static func encode(_ value: UInt64) -> String {
        value == 0 ? "0x0" : "0x" + String(value, radix: 16)
    }

    static func encode(_ bytes: Data) -> String {
        var trimmed = bytes
        while trimmed.first == 0 { trimmed = trimmed.dropFirst() }
        guard !trimmed.isEmpty else { return "0x0" }
        let text = trimmed.map { String(format: "%02x", $0) }.joined()
        return "0x" + (text.first == "0" ? String(text.dropFirst()) : text)
    }

    /// Nodes are not consistent about leading zeros in what they return, so parsing is
    /// lenient where rendering is strict.
    static func bytes(_ text: String) throws -> Data {
        guard text.count >= 2, text.hasPrefix("0x") || text.hasPrefix("0X") else {
            throw Failure.notAQuantity(text)
        }
        var digits = String(text.dropFirst(2))
        guard !digits.isEmpty else { throw Failure.notAQuantity(text) }
        if digits.count % 2 == 1 { digits = "0" + digits }
        guard let parsed = try? ABIWord.hexBytes("0x" + digits) else {
            throw Failure.notAQuantity(text)
        }
        var trimmed = parsed
        while trimmed.count > 1, trimmed.first == 0 { trimmed = trimmed.dropFirst() }
        return Data(trimmed)
    }

    /// Throws rather than truncating. A balance in a token with eighteen decimals
    /// outgrows a `UInt64` at about eighteen units, and a silently wrapped balance is a
    /// number the user would act on.
    static func uint64(_ text: String) throws -> UInt64 {
        let bytes = try bytes(text)
        guard bytes.count <= 8 else { throw Failure.tooLargeForUInt64(text) }
        return bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }
}
