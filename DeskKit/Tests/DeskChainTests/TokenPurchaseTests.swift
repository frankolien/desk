import DeskAuth
import DeskMoney
import DeskNet
import Foundation
import Testing
@testable import DeskChain

@Suite("Token purchase with AUSD")
struct TokenPurchaseTests {
    let holder = "0x0000000000001ff3684f28c67538d4d072c22734"
    let chog = "0xe0590015a873bf326bd645c3e1266d4db41c4e6b"
    let ausd = Money(text: "12.5")!
    let floor = "4158000000000000000000"
    let quotedData = "0x2213bc0b"
        + "0000000000000000000000002e73afeb01595831a67e9e1a56e193b93331b8c7"
        + "00000000000000000000000000000000efe302beaa2b3e6e1b18d08d69a9012a"
        + "0000000000000000000000000000000000000000000000000000000000bebc20"
        + String(repeating: "ab", count: 32 * 3)

    private func purchase(
        chainID: UInt64 = 143, to: String? = nil, data: String? = nil, value: String = "0",
        token: String? = nil, amount: Money? = nil, minimum: String? = nil
    ) throws -> TokenPurchase {
        try TokenPurchase(chainID: chainID, to: to ?? holder, data: data ?? quotedData, value: value,
                          token: token ?? chog, amount: amount ?? ausd, minimumOutRaw: minimum ?? floor)
    }

    @Test("a live quote's transaction is accepted and carries nothing")
    func accepts() throws {
        let checked = try purchase(to: "0x0000000000001fF3684f28c67538d4D072C22734", value: "")
        #expect(checked.amount == ausd)
        #expect(checked.minimumOutRaw == 4_158_000_000_000_000_000_000)
        #expect(checked.token.checksummed.lowercased() == chog)
        #expect(checked.to.checksummed.lowercased() == holder)
    }

    @Test("MON riding along, a strange contract or a strange call is refused")
    func refusals() {
        #expect(throws: TokenPurchase.Failure.amountMismatch) { try purchase(value: "1") }
        #expect(throws: TokenPurchase.Failure.amountMismatch) { try purchase(amount: .zero) }
        #expect(throws: TokenPurchase.Failure.wrongChain(10143)) { try purchase(chainID: 10143) }
        #expect(throws: TokenPurchase.Failure.unknownContract("0x4cd00e387622c35bddb9b4c962c136462338bc31")) {
            try purchase(to: "0x4cd00e387622c35bddb9b4c962c136462338bc31")
        }
        #expect(throws: TokenPurchase.Failure.unexpectedCall) { try purchase(data: "0xa9059cbb" + String(repeating: "00", count: 32 * 6)) }
        #expect(throws: TokenPurchase.Failure.unknownContract(holder)) { try purchase(token: holder) }
        #expect(throws: TokenPurchase.Failure.malformed) { try purchase(minimum: "0") }
        #expect(throws: TokenPurchase.Failure.malformed) { try purchase(minimum: "4.2") }
    }
}
