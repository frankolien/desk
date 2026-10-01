import Foundation
import Security

/// One value for both the canonical string and the headers: the gateway recomputes the
/// string from the headers, so any drift between the two is a rejected signature.
public struct RequestStamp: Sendable, Hashable {
    public let timestampMilliseconds: Int64
    public let nonce: String

    public init(timestampMilliseconds: Int64, nonce: String) {
        self.timestampMilliseconds = timestampMilliseconds
        self.nonce = nonce
    }

    public var timestampText: String { String(timestampMilliseconds) }

    public static func generate(now: Date = Date()) -> RequestStamp {
        var bytes = [UInt8](repeating: 0, count: 16)
        // SecRandomCopyBytes, never Int.random: a predictable nonce is a replayable one.
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        }
        return RequestStamp(
            timestampMilliseconds: Int64(now.timeIntervalSince1970 * 1000),
            nonce: Base64URL.encode(Data(bytes)))
    }
}
