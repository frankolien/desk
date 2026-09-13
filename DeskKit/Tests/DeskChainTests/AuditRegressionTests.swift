import DeskAuth
import Foundation
import Testing

@testable import DeskChain

/// Every case here is a defect the 13 September audit of DeskChain found, each of which
/// the module's own tests passed at the time. They stay as the reason the fix stays.

@Suite("Audit: typed data the wallet key must refuse")
struct SigningGuardTests {
    private func payload() throws -> EIP712.TypedData {
        let url = try #require(Bundle.module.url(forResource: "EnrolmentPayload", withExtension: "json"))
        struct Envelope: Decodable { let typed_data: EIP712.TypedData }
        return try JSONDecoder().decode(Envelope.self, from: try Data(contentsOf: url)).typed_data
    }

    private let signer = "0x50B240678777451BEfd67B7e8c3b4366482ba8F9"

    @Test("The real enrolment payload passes every check")
    func realPayloadPasses() throws {
        let expectation = EIP712.Expectation.perplEnrolment(signer: signer, chainID: 10143)
        let checked = try EIP712.digest(try payload(), expecting: expectation)
        #expect(checked == (try EIP712.digest(try payload())))
    }

    /// The one that matters. Hashing cannot tell an enrolment from a permit, and the
    /// wallet key signs the result, so an unlimited AUSD allowance is one hostile
    /// response away unless the shape itself is pinned.
    @Test("A permit served in place of an enrolment is refused")
    func permitIsRefused() throws {
        let permit = EIP712.TypedData(
            types: [
                "EIP712Domain": [
                    .init(name: "name", type: "string"), .init(name: "version", type: "string"),
                    .init(name: "chainId", type: "uint256"), .init(name: "verifyingContract", type: "address"),
                    .init(name: "salt", type: "bytes32"),
                ],
                "Permit": [
                    .init(name: "owner", type: "address"), .init(name: "spender", type: "address"),
                    .init(name: "value", type: "uint256"), .init(name: "nonce", type: "uint256"),
                    .init(name: "deadline", type: "uint256"),
                ],
            ],
            primaryType: "Permit",
            domain: [
                "name": .string("AUSD"), "version": .string("1"),
                "chainId": .string("0x279f"),
                "verifyingContract": .string("0xa9012a055bd4e0edff8ce09f960291c09d5322dc"),
                "salt": .string("0x" + String(repeating: "00", count: 32)),
            ],
            message: [
                "owner": .string(signer),
                "spender": .string("0x000000000000000000000000000000000000dEaD"),
                "value": .string("115792089237316195423570985008687907853269984665640564039457584007913129639935"),
                "nonce": .string("0"),
                "deadline": .string("115792089237316195423570985008687907853269984665640564039457584007913129639935"),
            ])

        // It hashes perfectly well, which is exactly the problem.
        #expect(throws: Never.self) { try EIP712.digest(permit) }
        #expect(throws: (any Error).self) {
            try EIP712.digest(permit, expecting: .perplEnrolment(signer: signer, chainID: 10143))
        }
    }

    @Test("A payload naming somebody else as the signer is refused")
    func foreignSignerIsRefused() throws {
        var message = try payload().message
        message["signer"] = .string("0x000000000000000000000000000000000000dEaD")
        let tampered = EIP712.TypedData(
            types: try payload().types, primaryType: "PerplRegisterApiKey",
            domain: try payload().domain, message: message)
        #expect(throws: (any Error).self) {
            try EIP712.digest(tampered, expecting: .perplEnrolment(signer: signer, chainID: 10143))
        }
    }

    @Test("A payload for another chain is refused")
    func wrongChainIsRefused() throws {
        #expect(throws: EIP712.GuardFailure.chainIDNotAllowed("0x279f")) {
            try EIP712.digest(try payload(), expecting: .perplEnrolment(signer: signer, chainID: 143))
        }
    }

    @Test("A reworded statement is refused, even when every type matches")
    func rewordedStatementIsRefused() throws {
        var message = try payload().message
        message["statement"] = .string("I authorize anything at all")
        let tampered = EIP712.TypedData(
            types: try payload().types, primaryType: "PerplRegisterApiKey",
            domain: try payload().domain, message: message)
        #expect(throws: EIP712.GuardFailure.statementNotAsExpected("I authorize anything at all")) {
            try EIP712.digest(tampered, expecting: .perplEnrolment(signer: signer, chainID: 10143))
        }
    }

    @Test("A field the type does not declare is not silently left out of the signature")
    func undeclaredFieldIsRefused() throws {
        var message = try payload().message
        message["recipient"] = .string("0x000000000000000000000000000000000000dEaD")
        let tampered = EIP712.TypedData(
            types: try payload().types, primaryType: "PerplRegisterApiKey",
            domain: try payload().domain, message: message)
        #expect(throws: EIP712.GuardFailure.messageHasUndeclaredFields(["recipient"])) {
            try EIP712.digest(tampered, expecting: .perplEnrolment(signer: signer, chainID: 10143))
        }
    }
}

@Suite("Audit: encoding against viem")
struct ViemVectorTests {
    struct Vector: Decodable {
        let label: String
        let encodeType: String
        let types: [String: [EIP712.Field]]
        let message: [String: JSONValue]
        let structHash: String?
        let rejected: String?
    }

    static let vectors: [Vector] = {
        let url = Bundle.module.url(forResource: "EIP712Vectors", withExtension: "json")!
        return try! JSONDecoder().decode([Vector].self, from: try! Data(contentsOf: url))
    }()

    @Test("The canonical type string matches viem", arguments: vectors)
    func encodeType(vector: Vector) throws {
        #expect(try EIP712.encodeType("A", types: vector.types) == vector.encodeType)
    }

    @Test("The struct hash matches viem, or is refused where viem refuses", arguments: vectors)
    func structHash(vector: Vector) throws {
        let computed = try? EIP712.structHash(type: "A", data: vector.message, types: vector.types)
        guard let expected = vector.structHash else {
            #expect(computed == nil, "\(vector.label) should have been refused")
            return
        }
        let hex = "0x" + (try #require(computed)).map { String(format: "%02x", $0) }.joined()
        #expect(hex == expected, "\(vector.label)")
    }
}

@Suite("Audit: word encoding")
struct ABIWordRegressionTests {
    @Test("A sign prefix is not a hex digit")
    func signPrefixRefused() {
        // `UInt8("+f", radix: 16)` is 15, so delegating to it turned a forty-character
        // run of `+1+2+3…` into a real twenty-byte address inside a signed digest.
        #expect(throws: (any Error).self) {
            try ABIWord.address("+1+2+3+4+5+6+7+8+9+a+b+c+d+e+f+0+1+2+3+4")
        }
        #expect(throws: (any Error).self) { try ABIWord.uint("0x+f") }
        #expect(throws: (any Error).self) { try ABIWord.bytes32(String(repeating: "+f", count: 32)) }
    }

    @Test("Only ASCII digits are digits")
    func nonASCIIDigitsRefused() {
        // `Character.wholeNumberValue` answers for all of these, so `"١٠٠"` parsed as a
        // hundred and `"1²"` as twelve.
        for text in ["١٠٠", "１２３", "੧੨੩", "൧൨൩", "1²", "０"] {
            #expect(throws: (any Error).self, "\(text)") { try ABIWord.uint(text) }
        }
        #expect(throws: Never.self) { try ABIWord.uint("100") }
    }

    @Test("Odd-length hex is refused rather than truncated")
    func oddLengthRefused() throws {
        // Dropping the trailing nibble made `0xabc` and `0xab` hash alike: two payloads
        // under one signature.
        #expect(throws: ABIWord.Failure.oddLengthHex("0xabc")) { try ABIWord.hexBytes("0xabc") }
        #expect(throws: ABIWord.Failure.notHex("abcd")) { try ABIWord.hexBytes("abcd") }
        #expect(try ABIWord.hexBytes("0xabcd") == Data([0xab, 0xcd]))
        #expect(try ABIWord.hexBytes("0Xabcd") == Data([0xab, 0xcd]))
    }

    @Test("Leading zeros are padding, not width")
    func leadingZerosFit() throws {
        let padded = "0x" + String(repeating: "0", count: 67) + "1"
        #expect(try ABIWord.uint(padded) == (try ABIWord.uint("1")))
    }

    @Test("A width is a width")
    func widthsEnforced() {
        #expect(throws: Never.self) { try ABIWord.uint("255", bits: 8) }
        #expect(throws: ABIWord.Failure.outOfRange("256", type: "uint8")) { try ABIWord.uint("256", bits: 8) }
        #expect(throws: Never.self) { try ABIWord.uint("18446744073709551615", bits: 64) }
        #expect(throws: (any Error).self) { try ABIWord.uint("18446744073709551616", bits: 64) }
    }

    @Test("Signed integers are two's complement across the whole word")
    func signedIntegers() throws {
        #expect(try ABIWord.int("-1") == Data(repeating: 0xff, count: 32))
        #expect(try ABIWord.int("0") == Data(repeating: 0, count: 32))
        #expect(throws: (any Error).self) { try ABIWord.int("128", bits: 8) }
        #expect(throws: Never.self) { try ABIWord.int("127", bits: 8) }
        // The negative end reaches one further than the positive one.
        #expect(throws: Never.self) { try ABIWord.int("-128", bits: 8) }
        #expect(throws: (any Error).self) { try ABIWord.int("-129", bits: 8) }
    }

    @Test("bytesN is right-padded, the opposite of an integer")
    func bytesNPadding() throws {
        let word = try ABIWord.bytesN("0xdeadbeef", count: 4)
        #expect(word.prefix(4) == Data([0xde, 0xad, 0xbe, 0xef]))
        #expect(word.dropFirst(4).allSatisfy { $0 == 0 })
        // Routing it through `uint` would have left-padded and produced a wrong word.
        #expect(word != (try ABIWord.uint("0xdeadbeef")))
    }

    @Test("An address error reports a count that is actually wrong")
    func addressErrorIsHonest() {
        #expect(throws: ABIWord.Failure.wrongByteCount(expected: 20, got: 21)) {
            try ABIWord.address("0x" + String(repeating: "ab", count: 21))
        }
    }
}

@Suite("Audit: numbers from an RPC node")
struct HostileNodeTests {
    @Test("A gas estimate too large to be one is refused, not trapped on")
    func gasEstimateOverflow() {
        // `estimate * 10_750 + 9_999` traps above 1_715_976_192_903_213, and a trap is a
        // dead process rather than a caught error. `eth_estimateGas` is a hex quantity
        // from whatever node the app was pointed at.
        #expect(throws: GasPolicy.Failure.estimateNotUsable(UInt64.max)) {
            try GasPolicy.gasLimit(estimate: .max)
        }
        #expect(throws: GasPolicy.Failure.estimateNotUsable(0)) { try GasPolicy.gasLimit(estimate: 0) }
        #expect(throws: (any Error).self) { try GasPolicy.gasLimit(estimate: GasPolicy.blockGasLimit + 1) }
        #expect(throws: Never.self) { try GasPolicy.gasLimit(estimate: GasPolicy.blockGasLimit) }
    }

    @Test("A small estimate still clears the intrinsic floor")
    func gasEstimateFloor() throws {
        #expect(try GasPolicy.gasLimit(estimate: 1) == GasPolicy.plainTransferGas)
    }

    @Test("An absurd base fee saturates rather than trapping")
    func baseFeeOverflow() {
        #expect(GasPolicy.maxFeePerGas(baseFeeWei: .max) == UInt64.max)
        #expect(GasPolicy.maxFeePerGas(baseFeeWei: UInt64.max / 2) == UInt64.max)
    }

    @Test("A transaction count that cannot be one is refused")
    func nonceOverflow() async {
        let registry = NonceRegistry()
        let wallet = EthereumAddress(bytes: Data(hex: "50b240678777451befd67b7e8c3b4366482ba8f9"))!
        await #expect(throws: NonceRegistry.Failure.chainCountNotUsable(.max)) {
            try await registry.reserve(for: wallet, chainCount: .max)
        }
        await #expect(throws: Never.self) { try await registry.release(for: wallet, nonce: .max) }
    }

    @Test("A JSON number larger than Int64 does not break the whole payload")
    func bigJSONNumber() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("9223372036854775808".utf8))
        #expect(value.stringValue == "9223372036854775808")
        #expect(try ABIWord.uint(try #require(value.stringValue)) == (try ABIWord.uint("9223372036854775808")))
    }

    @Test("A number too long to read exactly is refused, never rounded")
    func lossyJSONNumber() {
        let huge = String(repeating: "9", count: 78)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(JSONValue.self, from: Data(huge.utf8))
        }
    }
}

@Suite("Audit: the faucet's reverts")
struct FaucetRevertTests {
    @Test("0x5274afe7 is OpenZeppelin's, not the faucet's")
    func safeERC20Selector() {
        // `cast sig` confirms it is `SafeERC20FailedOperation(address)`, raised for any
        // failed ERC-20 operation. Calling it "drained" told the user the faucet was
        // empty for a failure that had nothing to do with the balance.
        #expect(FaucetRevert(selector: Data(hex: "5274afe7")) == .transferFailed)
        #expect(Calldata.selector("SafeERC20FailedOperation(address)") == Data(hex: "5274afe7"))
    }
}
