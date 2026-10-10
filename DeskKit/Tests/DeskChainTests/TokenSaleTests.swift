import DeskAuth
import DeskMoney
import DeskNet
import Foundation
import Testing
@testable import DeskChain

@Suite("Token sale")
struct TokenSaleTests {
    let holder = "0x0000000000001ff3684f28c67538d4d072c22734"
    let shmon = "0x1b68626dca36c7fe922fd2d55e4f631d962de19c"
    let raw = "1000000000000000000"
    let floor = "1614097053600000000"
    // The head of a live 0x quote, 1 shMON to MON on Monad, 9 October 2026.
    let quotedData = "0x2213bc0b"
        + "0000000000000000000000002e73afeb01595831a67e9e1a56e193b93331b8c7"
        + "0000000000000000000000001b68626dca36c7fe922fd2d55e4f631d962de19c"
        + "0000000000000000000000000000000000000000000000000de0b6b3a7640000"
        + String(repeating: "ab", count: 32 * 3)

    private func sale(
        chainID: UInt64 = 143, to: String? = nil, data: String? = nil, value: String = "0",
        token: String? = nil, amount: String? = nil, minimum: String? = nil
    ) throws -> TokenSale {
        try TokenSale(chainID: chainID, to: to ?? holder, data: data ?? quotedData, value: value,
                      token: token ?? shmon, amountRaw: amount ?? raw, minimumOutRaw: minimum ?? floor)
    }

    @Test("a live quote's transaction is accepted and carries nothing")
    func accepts() throws {
        let checked = try sale(to: "0x0000000000001fF3684f28c67538d4D072C22734", value: "")
        #expect(checked.amountRaw == 1_000_000_000_000_000_000)
        #expect(checked.minimumOut.weiText == floor)
        #expect(checked.token.checksummed.lowercased() == shmon)
    }

    @Test("MON riding along, a strange contract or a strange call is refused")
    func refusals() {
        #expect(throws: TokenSale.Failure.amountMismatch) { try sale(value: "1") }
        #expect(throws: TokenSale.Failure.wrongChain(10143)) { try sale(chainID: 10143) }
        #expect(throws: TokenSale.Failure.unknownContract("0x4cd00e387622c35bddb9b4c962c136462338bc31")) {
            try sale(to: "0x4cd00e387622c35bddb9b4c962c136462338bc31")
        }
        #expect(throws: TokenSale.Failure.unexpectedCall) { try sale(data: "0xa9059cbb" + String(repeating: "00", count: 32 * 6)) }
        #expect(throws: TokenSale.Failure.unknownContract(holder)) { try sale(token: holder) }
    }

    @Test("the amount sold and the floor must be positive counts")
    func counts() {
        #expect(throws: TokenSale.Failure.amountMismatch) { try sale(amount: "0") }
        #expect(throws: TokenSale.Failure.amountMismatch) { try sale(amount: "1.5") }
        #expect(throws: TokenSale.Failure.malformed) { try sale(minimum: "0") }
        #expect(throws: TokenSale.Failure.malformed) { try sale(minimum: "") }
    }
}
