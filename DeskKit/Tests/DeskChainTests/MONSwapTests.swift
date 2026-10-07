import DeskAuth
import DeskMoney
import Foundation
import Testing
@testable import DeskChain

@Suite("MON swap, AUSD sold")
struct MONSwapTests {
    let twelveAndAHalf = Money(text: "12.5")!
    let floor = NativeAmount(decimalText: "502.92")!
    let holder = "0x0000000000001ff3684f28c67538d4d072c22734"
    let quotedData = "0x2213bc0b"
        + "0000000000000000000000002e73afeb01595831a67e9e1a56e193b93331b8c7"
        + String(repeating: "00", count: 32)
        + String(repeating: "ab", count: 32 * 4)

    private func swap(
        chainID: UInt64 = 143, to: String? = nil, data: String? = nil, value: String = "0",
        amount: Money? = nil, minimum: NativeAmount? = nil
    ) throws -> MONSwap {
        try MONSwap(chainID: chainID, to: to ?? holder, data: data ?? quotedData, value: value,
                    amount: amount ?? twelveAndAHalf, minimumOut: minimum ?? floor)
    }

    @Test("a live quote's transaction is accepted with nothing sent along, in any address case")
    func accepts() throws {
        let checked = try swap(to: "0x0000000000001fF3684f28c67538d4D072C22734", value: "")
        #expect(checked.amount == twelveAndAHalf)
        #expect(checked.minimumOut == floor)
        #expect(checked.to.checksummed.lowercased() == holder)
        #expect(checked.data.prefix(4) == Data([0x22, 0x13, 0xbc, 0x0b]))
        _ = try swap(value: "0x0")
    }

    @Test("MON riding along the call is refused", arguments: ["1", "500000000000000000000", "0x1b1ae4d6e2ef5000"])
    func value(_ value: String) {
        #expect(throws: MONSwap.Failure.amountMismatch) { try swap(value: value) }
    }

    @Test("another chain, another contract or another call is refused")
    func shape() {
        #expect(throws: MONSwap.Failure.wrongChain(10143)) { try swap(chainID: 10143) }
        #expect(throws: MONSwap.Failure.self) { try swap(to: "0x4cd00e387622c35bddb9b4c962c136462338bc31") }
        #expect(throws: MONSwap.Failure.unexpectedCall) { try swap(data: "0xa9059cbb" + quotedData.dropFirst(10)) }
        #expect(throws: MONSwap.Failure.malformed) { try swap(data: "0x2213bc0b00") }
    }

    @Test("nothing to sell, or no floor, is refused")
    func amounts() {
        #expect(throws: MONSwap.Failure.amountMismatch) { try swap(amount: .zero) }
        #expect(throws: MONSwap.Failure.malformed) { try swap(minimum: .zero) }
    }
}
