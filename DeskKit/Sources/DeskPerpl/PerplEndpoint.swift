import Foundation

/// One REST call, reduced to the two things that are signed: the target and the body.
///
/// `target` is built once, here, and both signed and sent. The gateway rebuilds the
/// canonical string from the request line it received, so any layer that re-encodes the
/// query between signing and sending produces a signature the gateway cannot reproduce.
/// Every character is therefore committed at construction and never handed to
/// `URLComponents`, which normalises.
public struct PerplEndpoint: Sendable, Hashable {
    public enum Method: String, Sendable, Hashable {
        case get = "GET"
        case post = "POST"
        case delete = "DELETE"
    }

    public enum Failure: Error, Equatable, Sendable {
        case pathMustBeAbsolute(String)
        case pathHasUnsafeCharacters(String)
        case bodyOnGet
    }

    public let method: Method
    public let target: String
    public let body: Data

    /// The path excludes the base URL's `/api` prefix. The gateway signs what follows it.
    public init(
        method: Method,
        path: String,
        query: [(name: String, value: String)] = [],
        body: Data = Data()
    ) throws {
        guard path.hasPrefix("/") else { throw Failure.pathMustBeAbsolute(path) }
        guard path.utf8.allSatisfy({ Self.isUnreserved($0) || $0 == UInt8(ascii: "/") }) else {
            throw Failure.pathHasUnsafeCharacters(path)
        }
        guard !(method == .get && !body.isEmpty) else { throw Failure.bodyOnGet }

        self.method = method
        self.body = body
        if query.isEmpty {
            target = path
        } else {
            let pairs = query.map { Self.percentEncoded($0.name) + "=" + Self.percentEncoded($0.value) }
            target = path + "?" + pairs.joined(separator: "&")
        }
    }

    /// RFC 3986 unreserved, applied to UTF-8 bytes rather than `Character`s: a grapheme
    /// cluster is not a byte, and encoding per cluster mangles anything outside ASCII.
    static func percentEncoded(_ text: String) -> String {
        var encoded = ""
        encoded.reserveCapacity(text.utf8.count)
        for byte in text.utf8 {
            if isUnreserved(byte) {
                encoded.unicodeScalars.append(UnicodeScalar(byte))
            } else {
                encoded.append("%")
                encoded.append(Self.hexDigits[Int(byte >> 4)])
                encoded.append(Self.hexDigits[Int(byte & 0x0f)])
            }
        }
        return encoded
    }

    private static let hexDigits = Array("0123456789ABCDEF")

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
            return true
        default:
            return false
        }
    }
}
