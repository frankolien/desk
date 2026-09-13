import DeskAuth
import Foundation

/// EIP-712 hashing over typed data whose shape the venue supplies.
///
/// Generic rather than hardcoded to Perpl's `PerplRegisterApiKey`, because the payload
/// is returned by the server and its fields have already changed once.
public enum EIP712 {
    public struct Field: Decodable, Sendable, Hashable {
        public let name: String
        public let type: String

        public init(name: String, type: String) {
            self.name = name
            self.type = type
        }
    }

    public struct TypedData: Decodable, Sendable {
        public let types: [String: [Field]]
        public let primaryType: String
        public let domain: [String: JSONValue]
        public let message: [String: JSONValue]

        public init(
            types: [String: [Field]], primaryType: String,
            domain: [String: JSONValue], message: [String: JSONValue]
        ) {
            self.types = types
            self.primaryType = primaryType
            self.domain = domain
            self.message = message
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case unknownType(String)
        case missingField(String, inType: String)
        case unsupportedFieldType(String)
        case valueNotAString(field: String)
    }

    /// keccak256(0x1901 || domainSeparator || structHash(primaryType, message)).
    ///
    /// Internal on purpose. This hashes whatever arrived, and what arrives is chosen by
    /// the server; the wallet key signs the result. `digest(_:expecting:)` is the way in.
    static func digest(_ typedData: TypedData) throws -> Data {
        var preimage = Data([0x19, 0x01])
        preimage.append(try domainSeparator(typedData))
        preimage.append(try structHash(
            type: typedData.primaryType, data: typedData.message, types: typedData.types))
        return Keccak.hash(preimage)
    }

    public static func domainSeparator(_ typedData: TypedData) throws -> Data {
        try structHash(type: "EIP712Domain", data: typedData.domain, types: typedData.types)
    }

    /// `Name(type1 name1,type2 name2)`, with referenced struct types appended in
    /// alphabetical order.
    public static func encodeType(_ primary: String, types: [String: [Field]]) throws -> String {
        guard let fields = types[primary] else { throw Failure.unknownType(primary) }

        var referenced = Set<String>()
        var pending = [primary]
        while let current = pending.popLast() {
            guard let currentFields = types[current] else { continue }
            for field in currentFields {
                let base = String(field.type.prefix(while: { $0 != "[" }))
                if types[base] != nil, base != primary, referenced.insert(base).inserted {
                    pending.append(base)
                }
            }
        }

        let render = { (name: String, fields: [Field]) in
            name + "(" + fields.map { "\($0.type) \($0.name)" }.joined(separator: ",") + ")"
        }
        var encoded = render(primary, fields)
        for name in referenced.sorted() {
            encoded += render(name, types[name] ?? [])
        }
        return encoded
    }

    public static func typeHash(_ primary: String, types: [String: [Field]]) throws -> Data {
        Keccak.hash(try encodeType(primary, types: types))
    }

    public static func structHash(
        type: String, data: [String: JSONValue], types: [String: [Field]]
    ) throws -> Data {
        guard let fields = types[type] else { throw Failure.unknownType(type) }
        var encoded = try typeHash(type, types: types)
        for field in fields {
            guard let value = data[field.name] else {
                throw Failure.missingField(field.name, inType: type)
            }
            encoded.append(try encode(value, as: field.type, types: types, field: field.name))
        }
        return Keccak.hash(encoded)
    }

    private static func encode(
        _ value: JSONValue, as type: String, types: [String: [Field]], field: String
    ) throws -> Data {
        if type.hasSuffix("]") {
            guard case .array(let elements) = value else { throw Failure.valueNotAString(field: field) }
            // The last bracket, not the first: `uint256[2][2]` is an array of
            // `uint256[2]`, and splitting at the first turns it into an array of scalars.
            guard let bracket = type.lastIndex(of: "[") else { throw Failure.unsupportedFieldType(type) }
            let element = String(type[type.startIndex..<bracket])
            var concatenated = Data()
            for item in elements {
                concatenated.append(try encode(item, as: element, types: types, field: field))
            }
            return Keccak.hash(concatenated)
        }

        if types[type] != nil {
            guard case .object(let nested) = value else { throw Failure.valueNotAString(field: field) }
            return try structHash(type: type, data: nested, types: types)
        }

        switch type {
        case "string":
            guard case .string(let text) = value else { throw Failure.valueNotAString(field: field) }
            return Keccak.hash(text)
        case "bytes":
            guard let text = value.stringValue else { throw Failure.valueNotAString(field: field) }
            return Keccak.hash(try ABIWord.hexBytes(text))
        case "address":
            guard let text = value.stringValue else { throw Failure.valueNotAString(field: field) }
            return try ABIWord.address(text)
        case "bool":
            guard case .bool(let flag) = value else { throw Failure.valueNotAString(field: field) }
            return ABIWord.bool(flag)
        default:
            if let width = integerWidth(type) {
                guard let text = value.stringValue else { throw Failure.valueNotAString(field: field) }
                return width.signed
                    ? try ABIWord.int(text, bits: width.bits)
                    : try ABIWord.uint(text, bits: width.bits)
            }
            if let count = bytesWidth(type) {
                guard let text = value.stringValue else { throw Failure.valueNotAString(field: field) }
                return try ABIWord.bytesN(text, count: count)
            }
            throw Failure.unsupportedFieldType(type)
        }
    }

    /// `uint8` and `int128` are not `uint256` wearing a label. Encoding an out-of-range
    /// value into a full word produces a digest a Solidity verifier will never agree
    /// with, because it hashes the truncated type.
    static func integerWidth(_ type: String) -> (signed: Bool, bits: Int)? {
        let signed: Bool
        let suffix: Substring
        if type.hasPrefix("uint") {
            signed = false
            suffix = type.dropFirst(4)
        } else if type.hasPrefix("int") {
            signed = true
            suffix = type.dropFirst(3)
        } else {
            return nil
        }
        if suffix.isEmpty { return (signed, 256) }
        guard let bits = asciiInteger(suffix), bits > 0, bits <= 256, bits % 8 == 0 else { return nil }
        return (signed, bits)
    }

    static func bytesWidth(_ type: String) -> Int? {
        guard type.hasPrefix("bytes") else { return nil }
        let suffix = type.dropFirst(5)
        guard let count = asciiInteger(suffix), count >= 1, count <= 32 else { return nil }
        return count
    }

    /// `Int("+8")` is 8, which would make `uint+8` a type. Digits only.
    private static func asciiInteger(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") })
        else { return nil }
        return Int(text)
    }

}
