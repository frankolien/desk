import Foundation
import Testing
@testable import DeskChain

/// Pinned to a payload fetched from Perpl's live testnet on 13 September 2026, with the
/// expected hashes computed by viem over the same bytes.
@Suite("EIP-712")
struct EIP712Tests {
    let payload: EIP712.TypedData

    struct Envelope: Decodable {
        let typedData: EIP712.TypedData
        let mac: String
        enum CodingKeys: String, CodingKey {
            case typedData = "typed_data"
            case mac
        }
    }

    init() throws {
        let url = try #require(Bundle.module.url(forResource: "EnrolmentPayload", withExtension: "json"))
        payload = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url)).typedData
    }

    @Test("the enrolment digest matches viem")
    func digestMatchesViem() throws {
        #expect(try EIP712.digest(payload).hex
            == "b57fe053266b9449f2ac34eada069eae0deb8b069d372ac77a80f13cf2fbe389")
    }

    @Test("the domain separator matches viem")
    func domainSeparatorMatchesViem() throws {
        #expect(try EIP712.domainSeparator(payload).hex
            == "082b934561ce1ec15d4e11c0c9f3002608101e46f3a5298d464842f31a384a92")
    }

    @Test("the encoded type is the one Perpl signs")
    func encodedType() throws {
        #expect(try EIP712.encodeType("PerplRegisterApiKey", types: payload.types)
            == "PerplRegisterApiKey(address signer,string statement,string publicKey,"
             + "string scope,string label,string expiresAt,string ipCidrs,string origin,"
             + "string builderId,string maxBuilderFeePer100K,uint64 time)")
        #expect(try EIP712.encodeType("EIP712Domain", types: payload.types)
            == "EIP712Domain(string name,string version,uint256 chainId,"
             + "address verifyingContract,bytes32 salt)")
    }

    // Two fields arrive as hex strings while typed as integers: chainId "0x279f" and
    // time "0x1a09a29c91c". Hashing either as characters gives a digest the gateway
    // rejects, and viem produces that wrong digest silently rather than throwing.
    @Test("hex-string integers hash as numbers")
    func hexStringIntegersHashAsNumbers() throws {
        #expect(try ABIWord.uint("0x279f") == ABIWord.uint("10143"))
        #expect(try ABIWord.uint("0x1a09a29c91c") == ABIWord.uint("1789292824860"))
        #expect(try ABIWord.uint("0x279f").hex
            == "000000000000000000000000000000000000000000000000000000000000279f")
    }

    // Declaring chainId as a string is what a naive implementation effectively does
    // with "0x279f". viem produces 0xae2a4c... that way, silently, and the gateway
    // answers 400.
    @Test("hashing the chain id as characters gives viem's wrong digest")
    func theTrapItself() throws {
        var types = payload.types
        types["EIP712Domain"] = payload.types["EIP712Domain"]?.map {
            $0.name == "chainId" ? EIP712.Field(name: "chainId", type: "string") : $0
        }
        let mistaken = EIP712.TypedData(
            types: types, primaryType: payload.primaryType,
            domain: payload.domain, message: payload.message)

        #expect(try EIP712.digest(mistaken).hex
            == "aee8829eb0bf1099111b188c181f41760fae0bc95466813acf68b09dbca3d90b")
        #expect(try EIP712.digest(mistaken) != EIP712.digest(payload))
    }

    @Test("a full-width uint256 decimal encodes without a big-integer type")
    func wideDecimal() throws {
        let max = "115792089237316195423570985008687907853269984665640564039457584007913129639935"
        #expect(try ABIWord.uint(max).hex == String(repeating: "ff", count: 32))
        #expect(throws: ABIWord.Failure.doesNotFitIn32Bytes(
            "115792089237316195423570985008687907853269984665640564039457584007913129639936")) {
            try ABIWord.uint("115792089237316195423570985008687907853269984665640564039457584007913129639936")
        }
    }

    @Test("addresses are left-padded to a word")
    func addressPadding() throws {
        #expect(try ABIWord.address("0x50B240678777451BEfd67B7e8c3b4366482ba8F9").hex
            == "00000000000000000000000050b240678777451befd67b7e8c3b4366482ba8f9")
        #expect(try ABIWord.address("0x0000000000000000000000000000000000000000").hex
            == String(repeating: "00", count: 32))
    }

    @Test("malformed integers are refused rather than coerced")
    func malformedRefused() {
        for text in ["", "  ", "abc", "0x", "12a", "-1", "1.5", "0xzz"] {
            #expect(throws: (any Error).self) { try ABIWord.uint(text) }
        }
    }

    @Test("a missing field fails loudly")
    func missingFieldFails() throws {
        var message = payload.message
        message.removeValue(forKey: "label")
        #expect(throws: EIP712.Failure.missingField("label", inType: "PerplRegisterApiKey")) {
            try EIP712.structHash(type: "PerplRegisterApiKey", data: message, types: payload.types)
        }
    }

    @Test("changing any signed field changes the digest")
    func digestIsBoundToEveryField() throws {
        let original = try EIP712.digest(payload)
        let tamperedValues = [
            "label": "tampered", "scope": "1", "publicKey": "tampered",
            "signer": "0x0000000000000000000000000000000000000001", "time": "0x1",
        ]
        for (field, replacement) in tamperedValues {
            var message = payload.message
            message[field] = .string(replacement)
            let tampered = EIP712.TypedData(
                types: payload.types, primaryType: payload.primaryType,
                domain: payload.domain, message: message)
            #expect(try EIP712.digest(tampered) != original, "\(field) is not bound")
        }
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
