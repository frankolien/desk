import DeskAuth
import DeskMoney
import DeskNet
import Foundation
import Testing
@testable import DeskChain

@Suite("Relay deposit paid in AUSD")
struct RelayTokenDepositTests {
    let depository = "0x4cd00e387622c35bddb9b4c962c136462338bc31"
    let wallet = EthereumAddress(bytes: AUSDSwap.bytes("b63b7c1c8b5f3b1e4f0a1a2b3c4d5e6f7a8b4c97")!)!
    let five = Money(text: "5")!
    // Relay's deposit for 5 AUSD on Monad buying PENGU on Base, 11 October 2026.
    let data = "0xe8017952"
        + "000000000000000000000000b63b7c1c8b5f3b1e4f0a1a2b3c4d5e6f7a8b4c97"
        + "00000000000000000000000000000000efe302beaa2b3e6e1b18d08d69a9012a"
        + "00000000000000000000000000000000000000000000000000000000004c4b40"
        + "8c42eae35c10880d98babeabe8c0b9cd7aa36a50f4a3c9002da3d069f5f781ab"

    private func deposit(chainID: UInt64 = 143, to: String? = nil, data: String? = nil, value: String = "0", amount: Money? = nil) throws -> RelayTokenDeposit {
        try RelayTokenDeposit(chainID: chainID, to: to ?? depository, data: data ?? self.data, value: value, wallet: wallet, amount: amount ?? five)
    }

    @Test("a live quote's deposit is accepted and carries nothing")
    func accepts() throws {
        let checked = try deposit(to: "0x4cD00E387622C35bDDB9b4c962C136462338BC31", value: "")
        #expect(checked.amount == five)
        #expect(checked.token.checksummed.lowercased() == "0x" + RelayTokenDeposit.ausd)
        #expect(checked.to.checksummed.lowercased() == depository)
    }

    @Test("another chain, contract, call, depositor, token, amount, or MON riding along is refused")
    func refusals() {
        #expect(throws: RelayDeposit.Failure.wrongChain(10143)) { try deposit(chainID: 10143) }
        #expect(throws: RelayDeposit.Failure.unknownContract("0x1111111111111111111111111111111111111111")) { try deposit(to: "0x1111111111111111111111111111111111111111") }
        #expect(throws: RelayDeposit.Failure.unexpectedCall) { try deposit(data: "0x49290c1c" + String(data.dropFirst(10))) }
        #expect(throws: RelayDeposit.Failure.malformed) { try deposit(data: String(data.dropLast(64))) }
        let other = data.replacingOccurrences(of: "b63b7c1c8b5f3b1e4f0a1a2b3c4d5e6f7a8b4c97", with: "1111111111111111111111111111111111111111")
        #expect(throws: RelayDeposit.Failure.depositorIsNotThisWallet) { try deposit(data: other) }
        let usdc = data.replacingOccurrences(of: "efe302beaa2b3e6e1b18d08d69a9012a", with: "754704bc059f8c67012fed69bc8a327a5aafb603".suffix(32).description)
        #expect(throws: RelayDeposit.Failure.unexpectedCall) { try deposit(data: usdc) }
        #expect(throws: RelayDeposit.Failure.amountMismatch) { try deposit(amount: Money(text: "5.000001")!) }
        #expect(throws: RelayDeposit.Failure.amountMismatch) { try deposit(value: "1") }
    }
}
