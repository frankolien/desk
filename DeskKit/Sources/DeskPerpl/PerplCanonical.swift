import CryptoKit
import Foundation

/// The strings Perpl signs, byte for byte: newline separated, no trailing newline. When Swift
/// and `reference/perpl/vectors.mjs` disagree, the script (proven on testnet) is right.
public enum PerplCanonical {
    public static let signInAction = "trading-ws-signin"

    /// chain_id, METHOD, target, timestamp, nonce, sha256(body) as lowercase hex. `target` is the
    /// path and query byte-exact as sent; a re-encoded query breaks the signature.
    public static func rest(
        chainID: UInt64,
        method: String,
        target: String,
        body: Data,
        stamp: RequestStamp
    ) -> String {
        [
            String(chainID),
            method,
            target,
            stamp.timestampText,
            stamp.nonce,
            sha256Hex(body),
        ].joined(separator: "\n")
    }

    /// chain_id, the literal action, timestamp, nonce.
    public static func signIn(chainID: UInt64, stamp: RequestStamp) -> String {
        [String(chainID), signInAction, stamp.timestampText, stamp.nonce].joined(separator: "\n")
    }

    static func sha256Hex(_ body: Data) -> String {
        SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    }
}
