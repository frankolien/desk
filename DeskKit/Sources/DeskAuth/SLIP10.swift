import Foundation

/// SLIP-0010 over ed25519, for the account at m/44'/501'/{index}'/0'.
///
/// Every step is hardened; ed25519 has no public parent derivation. The path says
/// Solana because that is the path Mera assigns its ed25519 account, and following Mera
/// exactly is worth more than a tidier path.
enum SLIP10 {
    /// `path` carries unhardened indices; every step is hardened here. Passing an
    /// already-hardened index is a programming error rather than a no-op: `|` is
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
