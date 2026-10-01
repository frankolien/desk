import Foundation
import P256K

public struct EthereumSignature: Sendable, Hashable {
    public let r: Data
    public let s: Data
    /// 0 or 1. EIP-1559 transactions carry this directly; EIP-191 and EIP-712 carry
    /// `v = yParity + 27`.
    public let yParity: UInt8

    public var v: UInt8 { yParity + 27 }

    public var serialized: Data { r + s + Data([v]) }

    public init(r: Data, s: Data, yParity: UInt8) {
        self.r = r
        self.s = s
        self.yParity = yParity
    }
}

/// Signs a 32-byte digest and hashes nothing: what a caller passes is exactly what gets
/// signed. The key exists only for the call.
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
            // libsecp256k1 always returns the low-s form EIP-2 requires; nothing to normalise.
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

public enum PersonalMessage {
    public static func digest(_ message: String) -> Data {
        let body = Data(message.utf8)
        let prefix = Data("\u{19}Ethereum Signed Message:\n\(body.count)".utf8)
        return Keccak.hash(prefix + body)
    }
}
