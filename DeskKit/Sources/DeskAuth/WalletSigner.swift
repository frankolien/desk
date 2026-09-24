import Foundation
import P256K

/// A secp256k1 signature in the shape Ethereum wants it.
public struct EthereumSignature: Sendable, Hashable {
    public let r: Data
    public let s: Data
    /// 0 or 1. EIP-1559 transactions carry this directly; EIP-191 and EIP-712 carry
    /// `v = yParity + 27`.
    public let yParity: UInt8

    public var v: UInt8 { yParity + 27 }

    /// 65 bytes, `r || s || v`, as `eth_sign` and every EIP-712 verifier expect.
    public var serialized: Data { r + s + Data([v]) }

    public init(r: Data, s: Data, yParity: UInt8) {
        self.r = r
        self.s = s
        self.yParity = yParity
    }
}

/// Signs a 32-byte digest with the wallet key.
///
/// The key exists only for the call. Everything above this signs digests, never bytes,
/// so nothing here hashes: what a caller passes is exactly what gets signed, and a
/// convenience that hashed first would make it possible to sign a structure the caller
/// never saw.
public enum WalletSigner {
    public enum Failure: Error, Equatable, Sendable {
        case digestMustBe32Bytes(Int)
        case keyRejected
        case signatureMalformed
    }

    public static func sign(digest: Data, with key: WalletKey) throws -> EthereumSignature {
        try sign(digest: digest, privateKey: key.privateKey)
    }

    public static func sign(digest: Data, privateKey: SecureBytes) throws -> EthereumSignature {
        guard digest.count == 32 else { throw Failure.digestMustBe32Bytes(digest.count) }

        return try privateKey.withUnsafeBytes { bytes in
            guard let key = try? P256K.Recovery.PrivateKey(dataRepresentation: Data(bytes)) else {
                throw Failure.keyRejected
            }
            // libsecp256k1 signs deterministically per RFC 6979 and always returns the
            // low-s form, which is what EIP-2 requires; there is no malleable half to
            // normalise away here.
            let signature = key.signature(for: Keccak256Digest(digest))
            guard let compact = try? signature.compactRepresentation,
                  compact.signature.count == 64,
                  (0...1).contains(compact.recoveryId)
            else { throw Failure.signatureMalformed }

            return EthereumSignature(
                r: Data(compact.signature.prefix(32)),
                s: Data(compact.signature.suffix(32)),
                yParity: UInt8(compact.recoveryId))
        }
    }
}

/// Presents an already-computed keccak256 digest to a library that only signs `Digest`s.
///
/// The signing call takes `some Digest` and hashes nothing itself, but CryptoKit's digest
/// types are all tied to their own hash function and Ethereum does not use any of them.
/// This adapter carries the thirty-two bytes and nothing else.
struct Keccak256Digest: Digest {
    static var byteCount: Int { 32 }

    private let bytes: Data

    init(_ bytes: Data) {
        precondition(bytes.count == Self.byteCount)
        self.bytes = bytes
    }

    func makeIterator() -> Data.Iterator { bytes.makeIterator() }

    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try bytes.withUnsafeBytes(body)
    }
}

/// EIP-191 personal messages: what `personal_sign` signs, and what every verifier of
/// a wallet's word about itself checks.
///
/// The prefix and the byte length make the digest impossible to confuse with a
/// transaction or a typed-data hash, so a signature over one of these can never be
/// replayed as anything that moves money.
public enum PersonalMessage {
    public static func digest(_ message: String) -> Data {
        let body = Data(message.utf8)
        let prefix = Data("\u{19}Ethereum Signed Message:\n\(body.count)".utf8)
        return Keccak.hash(prefix + body)
    }
}
