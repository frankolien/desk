import Foundation

/// Finds the exact bytes of a top-level key's value inside a JSON document.
///
/// Perpl's enrolment hands back a `typed_data` object and a `mac` over it, and the
/// enrol call has to send both back. Decoding the object and re-encoding it would
/// reorder its keys — Swift dictionaries have no order — and any mac computed over the
/// serialised form would then fail against bytes the server never produced. The Node
/// spike survived this only because JavaScript preserves key order through a parse.
///
/// So the object is never re-encoded. It is spliced back out of the response verbatim.
enum JSONSpan {
    enum Failure: Error, Equatable, Sendable {
        case notAnObject
        case keyNotFound(String)
        case malformed
    }

    static func value(of key: String, in document: Data) throws -> Data {
        let bytes = [UInt8](document)
        var index = try skipWhitespace(bytes, from: 0)
        guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else { throw Failure.notAnObject }
        index += 1

        while true {
            index = try skipWhitespace(bytes, from: index)
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { throw Failure.keyNotFound(key) }
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw Failure.malformed }

            let nameEnd = try endOfString(bytes, from: index)
            let name = String(decoding: bytes[(index + 1)..<(nameEnd - 1)], as: UTF8.self)

            index = try skipWhitespace(bytes, from: nameEnd)
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw Failure.malformed }
            index = try skipWhitespace(bytes, from: index + 1)

            let valueEnd = try endOfValue(bytes, from: index)
            if name == key { return Data(bytes[index..<valueEnd]) }

            index = try skipWhitespace(bytes, from: valueEnd)
            if index < bytes.count, bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { throw Failure.keyNotFound(key) }
            throw Failure.malformed
        }
    }

    private static func skipWhitespace(_ bytes: [UInt8], from start: Int) throws -> Int {
        var index = start
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09
            || bytes[index] == 0x0a || bytes[index] == 0x0d {
            index += 1
        }
        return index
    }

    /// Returns the index one past the closing quote. Escapes are honoured, so a `\"`
    /// inside a value does not end it.
    private static func endOfString(_ bytes: [UInt8], from start: Int) throws -> Int {
        var index = start + 1
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "\\") {
                index += 2
                continue
            }
            if bytes[index] == UInt8(ascii: "\"") { return index + 1 }
            index += 1
        }
        throw Failure.malformed
    }

    private static func endOfValue(_ bytes: [UInt8], from start: Int) throws -> Int {
        guard start < bytes.count else { throw Failure.malformed }
        switch bytes[start] {
        case UInt8(ascii: "\""):
            return try endOfString(bytes, from: start)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var index = start
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\""):
                    index = try endOfString(bytes, from: index)
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return index + 1 }
                default:
                    break
                }
                index += 1
            }
            throw Failure.malformed
        default:
            var index = start
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: ",") || byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]")
                    || byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d {
                    return index
                }
                index += 1
            }
            throw Failure.malformed
        }
    }
}
