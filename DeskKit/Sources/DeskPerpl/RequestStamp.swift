import Foundation
import Security

/// The timestamp and nonce a request is signed with.
///
/// One value used for both the canonical string and the headers. Generating them
/// separately is the bug this type exists to prevent: the gateway recomputes the
/// canonical string from the headers, so a millisecond of drift between the two is a
/// rejected signature that looks like a clock problem.
public struct RequestStamp: Sendable, Hashable {
    public let timestampMilliseconds: Int64
    /// Base64url, unpadded, 16 random bytes. Single-use at the gateway.
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
