import CryptoKit
import Foundation
import P256K

/// Mera's derivation rule, followed exactly. Changing any line here changes every
/// address the app has ever shown.
///
///     PRF salt      sha256("mera.prf.salt.v1")
///     PRF output    32 bytes, used as BIP-39 entropy
///     Seed          BIP-39 seed, empty passphrase, PBKDF2 2048 rounds
///     Wallet key    BIP-32, m/44'/60'/0'/0/{index}, secp256k1
///     Trading key   SLIP-0010, m/44'/501'/{index}'/0', ed25519, all hardened
public enum PasskeyAccounts {
    public enum Failure: Error, Equatable, Sendable {
        case prfOutputMustBe32Bytes(Int)
        case indexOutOfRange(UInt32)
        case evmDerivationFailed
        case ed25519DerivationFailed
        case addressDerivationFailed
    }

    public static let prfSalt: Data = Hashing.sha256(Data("mera.prf.salt.v1".utf8))

    /// The Ed25519 key Perpl trades with. Separate from the wallet key because a
    /// trading session must never materialise the key that can move collateral.
    public static func deriveTradingKey(prfOutput: Data, index: UInt32 = 0) throws -> TradingKey {
        var seed = try bip39Seed(prfOutput: prfOutput, index: index)
        defer { seed.resetBytes(in: 0..<seed.count) }

        var ed25519Seed = SLIP10.ed25519Seed(seed: seed, path: [44, 501, index, 0])
        defer { ed25519Seed.resetBytes(in: 0..<ed25519Seed.count) }

        guard let signer = try? Curve25519.Signing.PrivateKey(rawRepresentation: ed25519Seed)
        else { throw Failure.ed25519DerivationFailed }

        return TradingKey(seed: SecureBytes(ed25519Seed),
                          publicKey: signer.publicKey.rawRepresentation)
    }

    /// The secp256k1 key that signs contract calls. Derived for one signature and let
    /// go; nothing should hold the returned value past the call it was made for.
    public static func deriveWalletKey(prfOutput: Data, index: UInt32 = 0) throws -> WalletKey {
        var seed = try bip39Seed(prfOutput: prfOutput, index: index)
        defer { seed.resetBytes(in: 0..<seed.count) }

        let hardened = BIP32.hardenedOffset
        var wallet = try BIP32.derive(
            seed: seed, path: [44 | hardened, 60 | hardened, 0 | hardened, 0, index])
        defer { wallet.key.resetBytes(in: 0..<wallet.key.count) }

        return WalletKey(privateKey: SecureBytes(wallet.key),
                         address: try address(forPrivateKey: wallet.key))
    }

    /// The address alone, with the key wiped before returning. What the address guard
    /// and the Fund screen need.
    public static func deriveAddress(prfOutput: Data, index: UInt32 = 0) throws -> EthereumAddress {
        var seed = try bip39Seed(prfOutput: prfOutput, index: index)
        defer { seed.resetBytes(in: 0..<seed.count) }

        let hardened = BIP32.hardenedOffset
        var wallet = try BIP32.derive(
            seed: seed, path: [44 | hardened, 60 | hardened, 0 | hardened, 0, index])
        defer { wallet.key.resetBytes(in: 0..<wallet.key.count) }

        return try address(forPrivateKey: wallet.key)
    }

    private static func bip39Seed(prfOutput: Data, index: UInt32) throws -> Data {
        guard prfOutput.count == 32 else {
            throw Failure.prfOutputMustBe32Bytes(prfOutput.count)
        }
        // An index with the high bit set would harden the last EVM step and collapse
        // two ed25519 accounts onto one key.
        guard index < BIP32.hardenedOffset else { throw Failure.indexOutOfRange(index) }
        return BIP39.seed(mnemonic: try BIP39.mnemonic(entropy: prfOutput))
    }

    static func address(forPrivateKey key: Data) throws -> EthereumAddress {
        guard let signing = try? P256K.Signing.PrivateKey(
            dataRepresentation: key, format: .uncompressed)
        else { throw Failure.evmDerivationFailed }

        // keccak of the 64-byte public point, without its 0x04 prefix; last 20 bytes.
        let publicKey = Data(signing.publicKey.dataRepresentation.dropFirst())
        guard let address = EthereumAddress(bytes: Data(Hashing.keccak256(publicKey).suffix(20)))
        else { throw Failure.addressDerivationFailed }
        return address
    }
}

/// No mnemonic anywhere. The phrase is an intermediate that never leaves derivation, so
/// there is nothing for a screen to render even by accident and nothing to export.
public struct TradingKey: Sendable {
    public let seed: SecureBytes
    public let publicKey: Data

    init(seed: SecureBytes, publicKey: Data) {
        self.seed = seed
        self.publicKey = publicKey
    }

    /// Derives the public key rather than accepting one, for the same reason `WalletKey`
    /// derives its address: a pair that can disagree will eventually disagree, and here
    /// that means enrolling one key and signing with another.
    public init(seed: SecureBytes) throws {
        self.seed = seed
        self.publicKey = try seed.withUnsafeBytes { bytes in
            guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: Data(bytes)) else {
                throw PasskeyAccounts.Failure.ed25519DerivationFailed
            }
            return key.publicKey.rawRepresentation
        }
    }
}

public struct WalletKey: Sendable {
    public let privateKey: SecureBytes
    public let address: EthereumAddress

    init(privateKey: SecureBytes, address: EthereumAddress) {
        self.privateKey = privateKey
        self.address = address
    }

    /// Derives the address rather than accepting one. A memberwise initialiser would let
    /// the two disagree, and a key that signs as one address while the screen shows
    /// another is a withdrawal sent nowhere.
    public init(privateKey: SecureBytes) throws {
        self.privateKey = privateKey
        self.address = try privateKey.withUnsafeBytes {
            try PasskeyAccounts.address(forPrivateKey: Data($0))
        }
    }
}
