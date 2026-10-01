import CryptoKit
import Foundation
import P256K

/// Mera's derivation rule, followed exactly: any change moves every address the app has ever shown.
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

        let publicKey = Data(signing.publicKey.dataRepresentation.dropFirst())
        guard let address = EthereumAddress(bytes: Data(Hashing.keccak256(publicKey).suffix(20)))
        else { throw Failure.addressDerivationFailed }
        return address
    }
}

public struct TradingKey: Sendable {
    public let seed: SecureBytes
    public let publicKey: Data

    init(seed: SecureBytes, publicKey: Data) {
        self.seed = seed
        self.publicKey = publicKey
    }

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

    public init(privateKey: SecureBytes) throws {
        self.privateKey = privateKey
        self.address = try privateKey.withUnsafeBytes {
            try PasskeyAccounts.address(forPrivateKey: Data($0))
        }
    }
}
