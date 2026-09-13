import DeskAuth
import Foundation

/// An EIP-1559 transaction, type `0x02`. Monad takes nothing older.
public struct Transaction: Sendable, Hashable {
    public let chainID: UInt64
    public let nonce: UInt64
    public let maxPriorityFeePerGas: UInt64
    public let maxFeePerGas: UInt64
    public let gasLimit: UInt64
    public let to: EthereumAddress?
    /// Big-endian wei. Held as bytes rather than a `UInt64` because a balance in a
    /// token with eighteen decimals outgrows one at about eighteen units.
    public let value: Data
    public let data: Data

    public init(
        chainID: UInt64,
        nonce: UInt64,
        maxPriorityFeePerGas: UInt64,
        maxFeePerGas: UInt64,
        gasLimit: UInt64,
        to: EthereumAddress?,
        value: Data = Data(),
        data: Data = Data()
    ) {
        self.chainID = chainID
        self.nonce = nonce
        self.maxPriorityFeePerGas = maxPriorityFeePerGas
        self.maxFeePerGas = maxFeePerGas
        self.gasLimit = gasLimit
        self.to = to
        self.value = value
        self.data = data
    }

    public static let type: UInt8 = 0x02

    /// The nine fields that are signed. The access list is present and empty — omitting
    /// it shortens the list and changes the digest.
    private var unsignedFields: [RLP.Item] {
        [
            RLP.quantity(chainID),
            RLP.quantity(nonce),
            RLP.quantity(maxPriorityFeePerGas),
            RLP.quantity(maxFeePerGas),
            RLP.quantity(gasLimit),
            .bytes(to?.bytes ?? Data()),
            RLP.quantity(value),
            .bytes(data),
            .list([]),
        ]
    }

    public var signingPayload: Data {
        Data([Self.type]) + RLP.encode(.list(unsignedFields))
    }

    public var signingDigest: Data { Keccak.hash(signingPayload) }

    public func signed(with signature: EthereumSignature) -> SignedTransaction {
        let fields = unsignedFields + [
            RLP.quantity(UInt64(signature.yParity)),
            RLP.quantity(signature.r),
            RLP.quantity(signature.s),
        ]
        let encoded = Data([Self.type]) + RLP.encode(.list(fields))
        return SignedTransaction(raw: encoded, hash: Keccak.hash(encoded), transaction: self)
    }

    public func signed(with key: WalletKey) throws -> SignedTransaction {
        signed(with: try WalletSigner.sign(digest: signingDigest, with: key))
    }
}

public struct SignedTransaction: Sendable, Hashable {
    public let raw: Data
    /// The hash the chain will know it by, available before it is sent.
    public let hash: Data
    public let transaction: Transaction

    public var rawHex: String { "0x" + raw.map { String(format: "%02x", $0) }.joined() }
    public var hashHex: String { "0x" + hash.map { String(format: "%02x", $0) }.joined() }
}
