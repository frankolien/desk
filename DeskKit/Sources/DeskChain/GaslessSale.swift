import DeskAuth
import Foundation

/// A token on another EVM chain sold for AUSD on Monad without that chain's gas. The wallet
/// lends itself Calibur's code, Uniswap's audited batch executor, by an EIP-7702 authorization
/// signed off-chain, and signs the approval and the Relay deposit as one batch; Relay's relayer
/// submits the transaction and takes the gas from the proceeds. Every field comes from a quote
/// service, so signing is allowed only for that pair of calls: an approval on the sold token,
/// for exactly the typed amount, to Relay's router, and a deposit on that router carrying nothing.
public struct GaslessSale: Sendable, Hashable {
    public enum Failure: Error, Equatable, Sendable {
        case wrongChain(UInt64)
        case unexpectedCalls
        case approvalNotAsExpected
        case unknownContract(String)
        case malformed
    }

    /// Calibur, at the same address on every chain it is deployed to.
    public static let calibur = "000000009b1d0af20d8c6d0a44e162d11f9b8f00"
    /// Relay's router: the approval's spender and the deposit's target, the same everywhere.
    public static let relayRouter = "ccc88a9d1b4ed6b0eaba998850414b24f1c315be"
    static let approveSelector = "095ea7b3"

    public struct Call: Sendable, Hashable {
        public let to: EthereumAddress
        public let data: Data
    }

    public let chainID: UInt64
    public let wallet: EthereumAddress
    public let token: EthereumAddress
    public let calls: [Call]
    public let amountRaw: String
    public let batchNonce: String
    /// The wallet's transaction count on that chain, or nil once it already runs Calibur.
    public let authorizationNonce: UInt64?
    public let requestID: String

    public init(
        chainID: UInt64, wallet: EthereumAddress, token: String,
        calls: [(to: String, value: String, data: String)], amountRaw: String,
        batchNonce: String, authorizationNonce: UInt64?, requestID: String
    ) throws {
        guard chainID > 0, chainID != AUSDSwap.chainID else { throw Failure.wrongChain(chainID) }
        let sold = AUSDSwap.strip(token).lowercased()
        guard sold.count == 40, let tokenAddress = AUSDSwap.bytes(sold).flatMap(EthereumAddress.init(bytes:)),
              sold != Self.relayRouter, sold != Self.calibur
        else { throw Failure.unknownContract(token) }
        guard amountRaw.allSatisfy(\.isASCIIDigit), !amountRaw.isEmpty, amountRaw.count <= 78,
              amountRaw.first != "0" || amountRaw == "0", amountRaw != "0",
              batchNonce.allSatisfy(\.isASCIIDigit), !batchNonce.isEmpty, batchNonce.count <= 78,
              requestID.count == 66, requestID.hasPrefix("0x"),
              AUSDSwap.bytes(String(requestID.dropFirst(2))) != nil
        else { throw Failure.malformed }
        guard calls.count == 2, calls.allSatisfy({ $0.value.isEmpty || $0.value == "0" || $0.value == "0x0" }) else {
            throw Failure.unexpectedCalls
        }
        var checked: [Call] = []
        for call in calls {
            let target = AUSDSwap.strip(call.to).lowercased()
            guard target.count == 40, let address = AUSDSwap.bytes(target).flatMap(EthereumAddress.init(bytes:)),
                  let data = AUSDSwap.bytes(AUSDSwap.strip(call.data)), data.count >= 4
            else { throw Failure.malformed }
            checked.append(Call(to: address, data: data))
        }
        // The approval: on the sold token, to the router, for exactly the amount sold.
        let approval = checked[0]
        let expectedApproval = try AUSDSwap.bytes(Self.approveSelector)! + ABIWord.address("0x" + Self.relayRouter) + ABIWord.uint(amountRaw)
        guard approval.to.bytes == tokenAddress.bytes, approval.data == expectedApproval else {
            throw Failure.approvalNotAsExpected
        }
        // The deposit: on the router, whatever Relay's router call is; the approval bounds it.
        guard checked[1].to.bytes == AUSDSwap.bytes(Self.relayRouter) else { throw Failure.unknownContract(calls[1].to) }
        self.chainID = chainID
        self.wallet = wallet
        self.token = tokenAddress
        self.calls = checked
        self.amountRaw = amountRaw
        self.batchNonce = batchNonce
        self.authorizationNonce = authorizationNonce
        self.requestID = requestID
    }

    /// The EIP-7702 authorization: `keccak(0x05 ‖ rlp([chain_id, address, nonce]))`, delegating
    /// this wallet to Calibur on that chain. Nil once the wallet already runs it.
    public var authorizationDigest: Data? {
        guard let nonce = authorizationNonce else { return nil }
        let fields: [RLP.Item] = [
            RLP.quantity(chainID),
            .bytes(AUSDSwap.bytes(Self.calibur)!),
            RLP.quantity(nonce),
        ]
        return Keccak.hash(Data([0x05]) + RLP.encode(.list(fields)))
    }

    /// Calibur's `SignedBatchedCall`, signed by the wallet's own key: nonce from the account,
    /// the root key, any executor, no deadline, reverting if any call fails.
    public var batchTypedData: EIP712.TypedData {
        let hex = { (data: Data) in "0x" + data.map { String(format: "%02x", $0) }.joined() }
        let zero = "0x" + String(repeating: "0", count: 64)
        return EIP712.TypedData(
            types: [
                "EIP712Domain": [
                    .init(name: "name", type: "string"), .init(name: "version", type: "string"),
                    .init(name: "chainId", type: "uint256"), .init(name: "verifyingContract", type: "address"),
                    .init(name: "salt", type: "bytes32"),
                ],
                "SignedBatchedCall": [
                    .init(name: "batchedCall", type: "BatchedCall"), .init(name: "nonce", type: "uint256"),
                    .init(name: "keyHash", type: "bytes32"), .init(name: "executor", type: "address"),
                    .init(name: "deadline", type: "uint256"),
                ],
                "BatchedCall": [.init(name: "calls", type: "Call[]"), .init(name: "revertOnFailure", type: "bool")],
                "Call": [.init(name: "to", type: "address"), .init(name: "value", type: "uint256"), .init(name: "data", type: "bytes")],
            ],
            primaryType: "SignedBatchedCall",
            domain: [
                "name": .string("Calibur"), "version": .string("1.0.0"), "chainId": .string(String(chainID)),
                "verifyingContract": .string(hex(wallet.bytes)),
                "salt": .string("0x" + String(repeating: "0", count: 24) + Self.calibur),
            ],
            message: [
                "batchedCall": .object([
                    "calls": .array(calls.map { .object(["to": .string(hex($0.to.bytes)), "value": .string("0"), "data": .string(hex($0.data))]) }),
                    "revertOnFailure": .bool(true),
                ]),
                "nonce": .string(batchNonce),
                "keyHash": .string(zero),
                "executor": .string("0x" + String(repeating: "0", count: 40)),
                "deadline": .string("0"),
            ])
    }

    public func batchDigest() throws -> Data { try EIP712.digest(batchTypedData) }

    public struct Signatures: Sendable, Hashable {
        public let authorization: EthereumSignature?
        public let batch: EthereumSignature
    }

    /// Both signatures from the wallet key, in one hold of it.
    public func signatures(with key: WalletKey) throws -> Signatures {
        Signatures(
            authorization: try authorizationDigest.map { try WalletSigner.sign(digest: $0, with: key) },
            batch: try WalletSigner.sign(digest: batchDigest(), with: key))
    }
}
