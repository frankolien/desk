import DeskAuth
import Foundation
import Testing

@testable import DeskChain

@Suite("RLP")
struct RLPTests {
    private func hex(_ item: RLP.Item) -> String {
        RLP.encode(item).map { String(format: "%02x", $0) }.joined()
    }

    @Test("Zero is the empty string, never a zero byte")
    func zeroIsEmpty() {
        // `0x00` and `` are different preimages, so getting this wrong changes the
        // digest of every transaction with a zero field — which is most of them.
        #expect(hex(RLP.quantity(UInt64(0))) == "80")
        #expect(hex(RLP.quantity(Data([0, 0, 0]))) == "80")
        #expect(hex(.bytes(Data([0]))) == "00")
    }

    @Test("A single byte below 0x80 is its own encoding")
    func singleByte() {
        #expect(hex(RLP.quantity(UInt64(1))) == "01")
        #expect(hex(RLP.quantity(UInt64(0x7f))) == "7f")
        #expect(hex(RLP.quantity(UInt64(0x80))) == "8180")
    }

    @Test("Leading zeros are stripped from a quantity")
    func leadingZeros() {
        #expect(hex(RLP.quantity(Data([0x00, 0x00, 0x01, 0x02]))) == "820102")
        #expect(hex(RLP.quantity(UInt64(256))) == "820100")
    }

    @Test("The long form kicks in past fifty-five bytes")
    func longForm() {
        #expect(hex(.bytes(Data(repeating: 0xaa, count: 55))).hasPrefix("b7"))
        #expect(hex(.bytes(Data(repeating: 0xaa, count: 56))).hasPrefix("b838"))
        #expect(hex(.bytes(Data(repeating: 0xaa, count: 1024))).hasPrefix("b90400"))
    }

    @Test("The empty list and the empty string differ")
    func emptyList() {
        #expect(hex(.list([])) == "c0")
        #expect(hex(.bytes(Data())) == "80")
    }
}

@Suite("Transactions against viem")
struct TransactionVectorTests {
    struct Vector: Decodable {
        let label: String
        let chainId: UInt64
        let nonce: UInt64
        let maxPriorityFeePerGas: String
        let maxFeePerGas: String
        let gasLimit: String
        let to: String?
        let value: String
        let data: String
        let raw: String
        let hash: String
        let from: String
    }

    /// The canonical Ethereum test key, never funded anywhere.
    static let privateKey = Data(hex: "4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318")

    static let vectors: [Vector] = {
        let url = Bundle.module.url(forResource: "TransactionVectors", withExtension: "json")!
        return try! JSONDecoder().decode([Vector].self, from: try! Data(contentsOf: url))
    }()

    private func transaction(_ vector: Vector) throws -> Transaction {
        Transaction(
            chainID: vector.chainId,
            nonce: vector.nonce,
            maxPriorityFeePerGas: try #require(UInt64(vector.maxPriorityFeePerGas)),
            maxFeePerGas: try #require(UInt64(vector.maxFeePerGas)),
            gasLimit: try #require(UInt64(vector.gasLimit)),
            to: vector.to.flatMap { EthereumAddress(bytes: Data(hex: String($0.dropFirst(2)))) },
            value: try ABIWord.uint(vector.value).drop { $0 == 0 },
            data: vector.data == "0x" ? Data() : Data(hex: String(vector.data.dropFirst(2))))
    }

    @Test("The signed bytes and the hash match viem", arguments: vectors)
    func signedMatchesViem(vector: Vector) throws {
        let signed = try transaction(vector).signed(
            with: try WalletSigner.sign(
                digest: try transaction(vector).signingDigest,
                privateKey: SecureBytes(Self.privateKey)))
        #expect(signed.rawHex == vector.raw, "\(vector.label)")
        #expect(signed.hashHex == vector.hash, "\(vector.label)")
    }

    @Test("The hash is known before the transaction is sent", arguments: vectors)
    func hashIsKnownUpFront(vector: Vector) throws {
        let signed = try transaction(vector).signed(
            with: try WalletSigner.sign(
                digest: try transaction(vector).signingDigest,
                privateKey: SecureBytes(Self.privateKey)))
        #expect(signed.hashHex == vector.hash)
    }
}

@Suite("Wallet signing")
struct WalletSignerTests {
    static let testKey = Data(hex: "4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318")

    @Test("Only a thirty-two byte digest is signable")
    func digestLength() {
        let key = SecureBytes(Data(hex: "4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318"))
        #expect(throws: WalletSigner.Failure.digestMustBe32Bytes(31)) {
            try WalletSigner.sign(digest: Data(repeating: 1, count: 31), privateKey: key)
        }
        #expect(throws: WalletSigner.Failure.digestMustBe32Bytes(0)) {
            try WalletSigner.sign(digest: Data(), privateKey: key)
        }
    }

    @Test("Signing is deterministic, so a repeat is the same signature")
    func deterministic() throws {
        // Unlike CryptoKit's Ed25519, which is hedged. RFC 6979 means a signature can be
        // pinned to a vector rather than only verified.
        let key = SecureBytes(Data(hex: "4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318"))
        let digest = Keccak.hash("desk")
        let first = try WalletSigner.sign(digest: digest, privateKey: key)
        let second = try WalletSigner.sign(digest: digest, privateKey: key)
        #expect(first == second)
        #expect(first.serialized.count == 65)
        #expect(first.v == first.yParity + 27)
    }

    @Test("The address derived from a key matches viem's")
    func addressMatchesViem() throws {
        let key = try WalletKey(privateKey: SecureBytes(Self.testKey))
        #expect(key.address.checksummed == TransactionVectorTests.vectors[0].from)
    }

    @Test("An all-zero key is refused rather than producing a signature")
    func zeroKeyRefused() {
        #expect(throws: WalletSigner.Failure.keyRejected) {
            try WalletSigner.sign(digest: Data(repeating: 1, count: 32), privateKey: SecureBytes(Data(repeating: 0, count: 32)))
        }
    }
}
