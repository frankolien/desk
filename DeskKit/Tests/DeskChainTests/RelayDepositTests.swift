import DeskAuth
import Foundation
import Testing
@testable import DeskChain

@Suite("Relay deposit")
struct RelayDepositTests {
    let wallet = EthereumAddress(bytes: Data(hex: "03508bb71268bba25ecacc8f620e01866650532c"))!
    let twenty = NativeAmount(decimalText: "20")!
    // Taken from a live Relay quote, 20 MON on Monad to BRETT on Base, 17 September 2026.
    let quotedData = "0x49290c1c00000000000000000000000003508bb71268bba25ecacc8f620e01866650532ce9b05d9fbc6c3b7f329a86ffa9b322fab44bfe1facabc8d6517b276c917b8bda"
    let depository = "0x4cd00e387622c35bddb9b4c962c136462338bc31"

    private func deposit(
        chainID: UInt64 = 143, to: String? = nil, data: String? = nil,
        value: String = "20000000000000000000", amount: NativeAmount? = nil
    ) throws -> RelayDeposit {
        try RelayDeposit(chainID: chainID, to: to ?? depository, data: data ?? quotedData,
                         value: value, wallet: wallet, amount: amount ?? twenty)
    }

    @Test("a live quote's deposit is accepted")
    func accepts() throws {
        let checked = try deposit(to: "0x4cD00E387622C35bDDB9b4c962C136462338BC31")
        #expect(checked.value == twenty)
        #expect(checked.data.count == 68)
    }

    @Test("another chain is refused")
    func chain() {
        #expect(throws: RelayDeposit.Failure.wrongChain(10143)) { try deposit(chainID: 10143) }
    }

    @Test("any other contract is refused")
    func contract() {
        #expect(throws: RelayDeposit.Failure.self) {
            try deposit(to: "0xf17902d51fdff7bf50aacc78d6bb399baf88b479")
        }
    }

    @Test("a deposit credited to someone else is refused")
    func depositor() {
        let other = quotedData.replacingOccurrences(of: "03508bb71268bba25ecacc8f620e01866650532c",
                                                    with: "1111111111111111111111111111111111111111")
        #expect(throws: RelayDeposit.Failure.depositorIsNotThisWallet) { try deposit(data: other) }
    }

    @Test("a different call to the depository is refused")
    func call() {
        let other = "0xa9059cbb" + quotedData.dropFirst(10)
        #expect(throws: RelayDeposit.Failure.unexpectedCall) { try deposit(data: String(other)) }
    }

    @Test("a value other than the typed amount is refused", arguments: [
        "20000000000000000001", "0x1158e460913d00000", "", "0",
    ])
    func amount(value: String) {
        #expect(throws: RelayDeposit.Failure.self) { try deposit(value: value) }
    }

    @Test("truncated or padded calldata is refused")
    func malformed() {
        #expect(throws: RelayDeposit.Failure.malformed) { try deposit(data: String(quotedData.dropLast(2))) }
        #expect(throws: RelayDeposit.Failure.malformed) { try deposit(data: quotedData + "00") }
    }
}

@Suite("Native amount text")
struct NativeAmountTextTests {
    @Test("typed amounts become exact wei", arguments: [
        ("1", "1000000000000000000"), ("0.5", "500000000000000000"), (".25", "250000000000000000"),
        ("20.", "20000000000000000000"), ("0.000000000000000001", "1"), ("0", "0"),
    ])
    func parses(text: String, wei: String) {
        #expect(NativeAmount(decimalText: text)?.weiText == wei)
    }

    @Test("anything else is refused", arguments: [
        "", ".", "1.2.3", "-1", "1e3", "0.0000000000000000001", "1,5", " 1",
        "1000000000000000000000000000000000000",
    ])
    func refuses(text: String) {
        #expect(NativeAmount(decimalText: text) == nil)
    }

    @Test("value bytes are big-endian and trimmed")
    func bytes() {
        #expect(NativeAmount(decimalText: "20")!.bigEndianBytes.hex == "01158e460913d00000")
        #expect(NativeAmount.zero.bigEndianBytes.isEmpty)
    }
}
