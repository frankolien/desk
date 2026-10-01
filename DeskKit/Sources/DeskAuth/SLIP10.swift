import Foundation

/// m/44'/501'/{index}'/0', all hardened: Solana's path, because Mera uses it for its ed25519 account.
enum SLIP10 {
    /// `path` carries unhardened indices. An already-hardened one is an error, not a no-op: `|` is
    /// idempotent, so it would silently collapse two accounts onto one key.
    static func ed25519Seed(seed: Data, path: [UInt32]) -> Data {
        var digest = Hashing.hmacSHA512(key: Data("ed25519 seed".utf8), message: seed)
        var key = Data(digest.prefix(32))
        var chainCode = Data(digest.suffix(32))

        for step in path {
            precondition(step < BIP32.hardenedOffset, "path step is already hardened")
            let index = step | BIP32.hardenedOffset
            var message = Data([0])
            message.append(key)
            message.append(contentsOf: [
                UInt8(truncatingIfNeeded: index >> 24), UInt8(truncatingIfNeeded: index >> 16),
                UInt8(truncatingIfNeeded: index >> 8), UInt8(truncatingIfNeeded: index),
            ])
            digest = Hashing.hmacSHA512(key: chainCode, message: message)
            key = Data(digest.prefix(32))
            chainCode = Data(digest.suffix(32))
        }
        return key
    }
}
