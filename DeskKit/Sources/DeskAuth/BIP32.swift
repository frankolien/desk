import Foundation
import P256K

/// BIP-32 over secp256k1, for the EVM account at m/44'/60'/0'/0/{index}.
enum BIP32 {
    struct ExtendedKey {
        var key: Data
        var chainCode: Data
    }

    enum Failure: Error, Equatable, Sendable {
        case invalidChildKey(index: UInt32)
        case invalidMasterKey
    }

    static let hardenedOffset: UInt32 = 0x8000_0000

    static func master(seed: Data) throws -> ExtendedKey {
        let digest = Hashing.hmacSHA512(key: Data("Bitcoin seed".utf8), message: seed)
        let key = Data(digest.prefix(32))
        guard (try? P256K.Signing.PrivateKey(dataRepresentation: key)) != nil else {
            throw Failure.invalidMasterKey
        }
        return ExtendedKey(key: key, chainCode: Data(digest.suffix(32)))
    }

    /// BIP-32 says to proceed with the next index when the tweak lands on zero mod n.
    /// This throws instead: the odds are 2^-127, and returning a key from a path the
    /// caller did not ask for is the worse failure.
    static func child(of parent: ExtendedKey, index: UInt32) throws -> ExtendedKey {
        var message = Data()
        if index >= hardenedOffset {
            message.append(0)
            message.append(parent.key)
        } else {
            let parentKey = try P256K.Signing.PrivateKey(dataRepresentation: parent.key, format: .compressed)
            message.append(parentKey.publicKey.dataRepresentation)
        }
        message.append(contentsOf: [
            UInt8(truncatingIfNeeded: index >> 24), UInt8(truncatingIfNeeded: index >> 16),
            UInt8(truncatingIfNeeded: index >> 8), UInt8(truncatingIfNeeded: index),
        ])

        let digest = Hashing.hmacSHA512(key: parent.chainCode, message: message)
        // (IL + kpar) mod n, via libsecp256k1 rather than hand-rolled field arithmetic.
        guard let parentKey = try? P256K.Signing.PrivateKey(dataRepresentation: parent.key),
              let tweaked = try? parentKey.add([UInt8](digest.prefix(32)))
        else { throw Failure.invalidChildKey(index: index) }

        return ExtendedKey(key: tweaked.dataRepresentation, chainCode: Data(digest.suffix(32)))
    }

    static func derive(seed: Data, path: [UInt32]) throws -> ExtendedKey {
        try path.reduce(try master(seed: seed)) { try child(of: $0, index: $1) }
    }
}
