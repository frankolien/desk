import Foundation

/// Just enough of a JSON tree to hash typed data whose shape the venue decides.
public enum JSONValue: Decodable, Sendable, Hashable {
    case string(String)
    case integer(Int64)
    /// A JSON number that does not fit an `Int64`, kept as the literal it arrived as.
    /// Legal JSON, and a venue may send a `uint256` amount or a nonce this way; forcing
    /// every number through `Int64` made one oversized field break the whole payload.
    case number(String)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: any Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null; return }
        if let value = try? box.decode(Bool.self) { self = .bool(value); return }
        if let value = try? box.decode(Int64.self) { self = .integer(value); return }
        if let value = try? box.decode(String.self) { self = .string(value); return }
        if let value = try? box.decode(Decimal.self) {
            let text = "\(value)"
            // `Decimal` carries thirty-eight significant digits, and JSONDecoder offers
            // no way at the raw token. A longer literal would arrive rounded, and a
            // rounded number inside a signed digest is worse than a refused payload.
            guard text.filter(\.isNumber).count <= 38 else {
                throw DecodingError.dataCorruptedError(
                    in: box, debugDescription: "number too long to read exactly: \(text)")
            }
            self = .number(text)
            return
        }
        if let value = try? box.decode([JSONValue].self) { self = .array(value); return }
        self = .object(try box.decode([String: JSONValue].self))
    }

    public var stringValue: String? {
        switch self {
        case .string(let value): value
        case .integer(let value): String(value)
        case .number(let value): value
        default: nil
        }
    }
}
