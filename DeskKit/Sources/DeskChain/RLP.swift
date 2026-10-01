import Foundation

enum RLP {
    enum Item {
        case bytes(Data)
        case list([Item])
    }

    static func encode(_ item: Item) -> Data {
        switch item {
        case .bytes(let payload):
            // A single byte below 0x80 is its own encoding. Prefixing it anyway produces
            // a different transaction hash for the same transaction.
            if payload.count == 1, payload[0] < 0x80 { return payload }
            return header(count: payload.count, short: 0x80, long: 0xb7) + payload
        case .list(let items):
            let body = items.reduce(into: Data()) { $0 += encode($1) }
            return header(count: body.count, short: 0xc0, long: 0xf7) + body
        }
    }

    /// Leading zeros removed; zero is the empty string, never `0x00`. The two are different
    /// RLP, so getting this wrong quietly breaks the signature of any zero field.
    static func quantity(_ bytes: Data) -> Item {
        var trimmed = bytes
        while trimmed.first == 0 { trimmed = trimmed.dropFirst() }
        return .bytes(Data(trimmed))
    }

    static func quantity(_ value: UInt64) -> Item {
        quantity(Data(withUnsafeBytes(of: value.bigEndian) { Array($0) }))
    }

    private static func header(count: Int, short: UInt8, long: UInt8) -> Data {
        if count <= 55 { return Data([short + UInt8(count)]) }
        let length = minimalBytes(UInt64(count))
        return Data([long + UInt8(length.count)]) + length
    }

    private static func minimalBytes(_ value: UInt64) -> Data {
        var bytes = Data(withUnsafeBytes(of: value.bigEndian) { Array($0) })
        while bytes.first == 0 { bytes = bytes.dropFirst() }
        return Data(bytes)
    }
}
