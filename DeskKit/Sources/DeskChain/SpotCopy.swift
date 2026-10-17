import DeskAuth
import Foundation

/// Spot Auto-Copy (docs/spot-copy.md), the bytes the wallet signs: the Calibur batches that put
/// Desk's copy key on the wallet behind DeskCopyHook, change its limits and take it off, the
/// EIP-7702 authorization to Calibur on Monad, and the grant text naming the phone. The server
/// rebuilds every byte the same way (web/copyd/spot-chain.mjs, web/api/_spot.mjs) and refuses
/// anything else; the tests pin both to the same golden values.
public enum SpotCopy {
    public static let chainID: UInt64 = 143
    public static let calibur = "0x" + GaslessSale.calibur
    static let wallet = "0x0000000000000000000000000000000000000000" // ERC-7821: the wallet itself

    public struct Call: Sendable, Hashable {
        public let to: String
        public let data: Data
    }

    public enum Failure: Error, Equatable, Sendable {
        case notAnAddress(String)
        case hookBits(String)
    }

    /// Calibur's hash for a secp256k1 key: `keccak(abi.encode(uint8(2), keccak(abi.encode(address))))`.
    public static func keyHash(desk: String) throws -> Data {
        let inner = Keccak.hash(try ABIWord.address(desk))
        return Keccak.hash(try ABIWord.uint("2") + inner)
    }

    /// Calibur key settings: the hook in the low 20 bytes, the expiry above it, not an admin.
    public static func settings(hook: String, expiry: UInt64) throws -> Data {
        var word = try ABIWord.address(hook)
        var exp = expiry
        for index in stride(from: 11, through: 7, by: -1) {
            word[index] = UInt8(exp & 0xff)
            exp >>= 8
        }
        return word
    }

    /// The hook's callbacks are read from its address's low five bits: 11110.
    public static func checkHook(_ hook: String) throws {
        guard let bytes = AUSDSwap.bytes(AUSDSwap.strip(hook)), bytes.count == 20 else { throw Failure.notAnAddress(hook) }
        guard bytes[19] & 0x1f == 0x1e else { throw Failure.hookBits(hook) }
    }

    static func selector(_ signature: String) -> Data { Keccak.hash(signature).prefix(4) }
    static func ausd(_ whole: Int) throws -> Data { try ABIWord.uint(String(whole) + "000000") }

    /// Register Desk's key, fence it with the hook until `expiry`, set the AUSD limits.
    public static func setupCalls(desk: String, hook: String, expiry: UInt64, perTrade: Int, perDay: Int) throws -> [Call] {
        try checkHook(hook)
        let keyHash = try keyHash(desk: desk)
        let key = try ABIWord.uint("32") + ABIWord.uint("2") + ABIWord.uint("64") + ABIWord.uint("32") + ABIWord.address(desk)
        return [
            Call(to: wallet, data: selector("register((uint8,bytes))") + key),
            Call(to: wallet, data: selector("update(bytes32,uint256)") + keyHash + (try settings(hook: hook, expiry: expiry))),
            Call(to: hook.lowercased(), data: selector("configure(bytes32,uint128,uint128)") + keyHash + (try ausd(perTrade)) + (try ausd(perDay))),
        ]
    }

    /// A new end date and new limits.
    public static func limitCalls(desk: String, hook: String, expiry: UInt64, perTrade: Int, perDay: Int) throws -> [Call] {
        try checkHook(hook)
        let keyHash = try keyHash(desk: desk)
        return [
            Call(to: wallet, data: selector("update(bytes32,uint256)") + keyHash + (try settings(hook: hook, expiry: expiry))),
            Call(to: hook.lowercased(), data: selector("configure(bytes32,uint128,uint128)") + keyHash + (try ausd(perTrade)) + (try ausd(perDay))),
        ]
    }

    /// Desk's key off the wallet.
    public static func revokeCalls(desk: String) throws -> [Call] {
        [Call(to: wallet, data: selector("revoke(bytes32)") + (try keyHash(desk: desk)))]
    }

    /// Calibur's `SignedBatchedCall` for the wallet's root key, executable only by Desk's key.
    public static func batchTypedData(wallet address: String, calls: [Call], nonce: String, deadline: UInt64, executor: String) -> EIP712.TypedData {
        let hex = { (data: Data) in "0x" + data.map { String(format: "%02x", $0) }.joined() }
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
                "verifyingContract": .string(address),
                "salt": .string("0x" + String(repeating: "0", count: 24) + GaslessSale.calibur),
            ],
            message: [
                "batchedCall": .object([
                    "calls": .array(calls.map { .object(["to": .string($0.to), "value": .string("0"), "data": .string(hex($0.data))]) }),
                    "revertOnFailure": .bool(true),
                ]),
                "nonce": .string(nonce),
                "keyHash": .string("0x" + String(repeating: "0", count: 64)),
                "executor": .string(executor),
                "deadline": .string(String(deadline)),
            ])
    }

    /// The EIP-7702 authorization delegating the wallet to Calibur on Monad at `nonce`.
    public static func authorizationDigest(nonce: UInt64) -> Data {
        let fields: [RLP.Item] = [RLP.quantity(chainID), .bytes(AUSDSwap.bytes(GaslessSale.calibur)!), RLP.quantity(nonce)]
        return Keccak.hash(Data([0x05]) + RLP.encode(.list(fields)))
    }
}
