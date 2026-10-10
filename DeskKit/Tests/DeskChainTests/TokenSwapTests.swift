import DeskAuth
import DeskMoney
import DeskNet
import Foundation
import Testing
@testable import DeskChain

@Suite("Token swap")
struct TokenSwapTests {
    let ten = NativeAmount(decimalText: "10")!
    let holder = "0x0000000000001ff3684f28c67538d4d072c22734"
    let gochi = "0x527d86b0820a72f7dfb937fe1da0c649019b7777"
    // The head of a live 0x quote, 10 MON to GOCHI on Monad, 9 October 2026.
    let quotedData = "0x2213bc0b"
        + "0000000000000000000000002e73afeb01595831a67e9e1a56e193b93331b8c7"
        + "0000000000000000000000000000000000000000000000000000000000000000"
        + "0000000000000000000000000000000000000000000000008ac7230489e80000"
        + String(repeating: "ab", count: 32 * 3)
    let floor = "2184096770900000000000"

    private func swap(
        chainID: UInt64 = 143, to: String? = nil, data: String? = nil, value: String = "10000000000000000000",
        amount: NativeAmount? = nil, token: String? = nil, minimum: String? = nil
    ) throws -> TokenSwap {
        try TokenSwap(chainID: chainID, to: to ?? holder, data: data ?? quotedData, value: value,
                      amount: amount ?? ten, token: token ?? gochi, minimumOutRaw: minimum ?? floor)
    }

    @Test("a live quote's transaction is accepted, in any address case")
    func accepts() throws {
        let checked = try swap(to: "0x0000000000001fF3684f28c67538d4D072C22734", token: "0x527D86B0820A72F7DFB937FE1DA0C649019B7777")
        #expect(checked.value == ten)
        #expect(checked.minimumOutRaw == 2_184_096_770_900_000_000_000)
        #expect(checked.token.checksummed.lowercased() == gochi)
        #expect(checked.data.prefix(4) == Data([0x22, 0x13, 0xbc, 0x0b]))
    }

    @Test("another chain, another contract or another call is refused")
    func refusals() {
        #expect(throws: TokenSwap.Failure.wrongChain(1)) { try swap(chainID: 1) }
        #expect(throws: TokenSwap.Failure.unknownContract("0x4cd00e387622c35bddb9b4c962c136462338bc31")) {
            try swap(to: "0x4cd00e387622c35bddb9b4c962c136462338bc31")
        }
        #expect(throws: TokenSwap.Failure.unexpectedCall) { try swap(data: "0xa9059cbb" + String(repeating: "00", count: 32 * 6)) }
        #expect(throws: TokenSwap.Failure.malformed) { try swap(data: "0x2213bc0b") }
        #expect(throws: TokenSwap.Failure.unknownContract(holder)) { try swap(token: holder) }
    }

    @Test("the MON carried must be exactly the typed amount, and the floor must be a positive count")
    func amounts() {
        #expect(throws: TokenSwap.Failure.amountMismatch) { try swap(value: "10000000000000000001") }
        #expect(throws: TokenSwap.Failure.amountMismatch) { try swap(value: "0", amount: NativeAmount(decimalText: "0")!) }
        #expect(throws: TokenSwap.Failure.malformed) { try swap(minimum: "0") }
        #expect(throws: TokenSwap.Failure.malformed) { try swap(minimum: "12.5") }
        #expect(throws: TokenSwap.Failure.malformed) { try swap(minimum: String(repeating: "9", count: 40)) }
    }
}
