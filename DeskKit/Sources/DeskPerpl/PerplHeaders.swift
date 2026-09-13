import Foundation

public enum PerplHeaders {
    public static let apiKey = "X-API-Key"
    public static let timestamp = "X-API-Timestamp"
    public static let nonce = "X-API-Nonce"
    public static let signature = "X-API-Signature"

    public static func signed(apiKey key: String, stamp: RequestStamp, signature: String) -> [String: String] {
        [apiKey: key, timestamp: stamp.timestampText, nonce: stamp.nonce, self.signature: signature]
    }
}
