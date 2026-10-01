import CryptoKit
import DeskAuth
import Foundation

public struct PerplSigner: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case seedRejected
    }

    private let seed: SecureBytes

    public init(seed: SecureBytes) { self.seed = seed }

    /// CryptoKit's Ed25519 is hedged: the same bytes sign differently each time, so tests
    /// must verify a signature rather than compare it to a fixture.
    public func sign(_ canonical: String) throws -> String {
        let key = try signingKey()
        return Base64URL.encode(try key.signature(for: Data(canonical.utf8)))
    }

    public func publicKeyHex() throws -> String {
        "0x" + (try signingKey()).publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }.joined()
    }

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
