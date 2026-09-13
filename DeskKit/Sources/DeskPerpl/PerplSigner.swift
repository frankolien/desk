import CryptoKit
import DeskAuth
import Foundation

/// Signs Perpl's canonical strings with the Ed25519 key derived from the passkey.
///
/// Holds the seed rather than a key object and builds the signing key per use, so the
/// live key exists for the duration of one signature.
public struct PerplSigner: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case seedRejected
    }

    private let seed: SecureBytes

    public init(seed: SecureBytes) { self.seed = seed }

    /// CryptoKit's Ed25519 is hedged: signing the same bytes twice gives two different
    /// signatures, both valid. So a signature cannot be compared against a fixture from
    /// another implementation — it has to be verified. Perpl verifies rather than
    /// compares, and its idempotency comes from `rq`, so this is only a testing concern.
    public func sign(_ canonical: String) throws -> String {
        let key = try signingKey()
        return Base64URL.encode(try key.signature(for: Data(canonical.utf8)))
    }

    /// 32 bytes of 0x-hex, the shape `/api-key/payload` expects.
    public func publicKeyHex() throws -> String {
        "0x" + (try signingKey()).publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Verifies a signature over `canonical` against this key. Used to check our
    /// signing against the reference implementation's output.
    public func verify(_ signature: String, over canonical: String) throws -> Bool {
        guard let bytes = Base64URL.decode(signature) else { return false }
        return try signingKey().publicKey.isValidSignature(bytes, for: Data(canonical.utf8))
    }

    private func signingKey() throws -> Curve25519.Signing.PrivateKey {
        try seed.withUnsafeBytes { bytes in
            guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: Data(bytes))
            else { throw Failure.seedRejected }
            return key
        }
    }
}
