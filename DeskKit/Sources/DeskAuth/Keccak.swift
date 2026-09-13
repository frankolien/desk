import Foundation

public enum Keccak {
    /// Ethereum's keccak256, which is not NIST SHA3-256 — the padding differs.
    public static func hash(_ data: Data) -> Data { Hashing.keccak256(data) }
    public static func hash(_ text: String) -> Data { Hashing.keccak256(Data(text.utf8)) }
}
