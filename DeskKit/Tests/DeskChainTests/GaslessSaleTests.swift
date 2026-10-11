import DeskAuth
import DeskMoney
import DeskNet
import Foundation
import Testing
@testable import DeskChain

@Suite("Gasless sale on another chain")
struct GaslessSaleTests {
    let router = "0xccc88a9d1b4ed6b0eaba998850414b24f1c315be"
    let token = "0x01e6bd233f7021e4f5698a3ae44242b76a246c0a"
    let wallet = EthereumAddress(bytes: AUSDSwap.bytes("b63b7c1c8b5f3b1e4f0a1a2b3c4d5e6f7a8b4c97")!)!
    let amount = "3000000000000000000000"
    let requestID = "0x" + String(repeating: "ab", count: 32)
    // Relay's two calls for selling 3,000 PENGU on Base for AUSD on Monad, 11 October 2026.
    var approve: String { "0x095ea7b3" + String(repeating: "0", count: 24) + "ccc88a9d1b4ed6b0eaba998850414b24f1c315be" + String(repeating: "0", count: 46) + "a2a15d09519be00000" }
    var deposit: String { "0xf9e4bab4" + String(repeating: "ab", count: 96) }

    private func sale(
        chainID: UInt64 = 8453, token: String? = nil, calls: [(to: String, value: String, data: String)]? = nil,
        amount: String? = nil, batchNonce: String = "7", authorizationNonce: UInt64? = 12, requestID: String? = nil
    ) throws -> GaslessSale {
        try GaslessSale(
            chainID: chainID, wallet: wallet, token: token ?? self.token,
            calls: calls ?? [(self.token, "0", approve), (router, "0", deposit)],
            amountRaw: amount ?? self.amount, batchNonce: batchNonce,
            authorizationNonce: authorizationNonce, requestID: requestID ?? self.requestID)
    }

    private func hex(_ data: Data) -> String { "0x" + data.map { String(format: "%02x", $0) }.joined() }

    @Test("the authorization and the batch hash exactly as viem hashes them")
    func digests() throws {
        let checked = try sale()
        #expect(hex(checked.authorizationDigest!) == "0x9458ef490bde4af4ff7e45002e23c790b8863d6ab9f826a2fa1882a611d60fb9")
        #expect(hex(try checked.batchDigest()) == "0xeaaa9b0ed3bdb3e06fa68b1136e3d0ebdeb9996914348518b8b1a4a6d15baafc")
        #expect(try sale(authorizationNonce: nil).authorizationDigest == nil)
    }

    @Test("both signatures come from the wallet key and recover to it")
    func signs() throws {
        let key = try WalletKey(privateKey: SecureBytes(Data(repeating: 0x11, count: 32)))
        let checked = try GaslessSale(
            chainID: 8453, wallet: key.address, token: token,
            calls: [(token, "0", approve), (router, "0", deposit)],
            amountRaw: amount, batchNonce: "0", authorizationNonce: 0, requestID: requestID)
        let signatures = try checked.signatures(with: key)
        #expect(signatures.authorization != nil)
        #expect(signatures.batch.r.count == 32 && signatures.batch.s.count == 32)
        #expect(signatures.batch == (try WalletSigner.sign(digest: try checked.batchDigest(), with: key)))
    }

    @Test("Monad, a third call, MON riding along or an approval that is not exact is refused")
    func refusals() {
        #expect(throws: GaslessSale.Failure.wrongChain(143)) { try sale(chainID: 143) }
        #expect(throws: GaslessSale.Failure.unexpectedCalls) { try sale(calls: [(token, "0", approve)]) }
        #expect(throws: GaslessSale.Failure.unexpectedCalls) { try sale(calls: [(token, "0", approve), (router, "1", deposit)]) }
        #expect(throws: GaslessSale.Failure.unexpectedCalls) { try sale(calls: [(token, "0", approve), (router, "0", deposit), (router, "0", deposit)]) }
        #expect(throws: GaslessSale.Failure.approvalNotAsExpected) { try sale(amount: "3000000000000000000001") }
        #expect(throws: GaslessSale.Failure.approvalNotAsExpected) { try sale(calls: [(router, "0", approve), (router, "0", deposit)]) }
        let elsewhere = "0x095ea7b3" + String(repeating: "0", count: 24) + "1111111111111111111111111111111111111111" + String(repeating: "0", count: 46) + "a2a15d09519be00000"
        #expect(throws: GaslessSale.Failure.approvalNotAsExpected) { try sale(calls: [(token, "0", elsewhere), (router, "0", deposit)]) }
        #expect(throws: GaslessSale.Failure.unknownContract("0x1111111111111111111111111111111111111111")) {
            try sale(calls: [(token, "0", approve), ("0x1111111111111111111111111111111111111111", "0", deposit)])
        }
        #expect(throws: GaslessSale.Failure.unknownContract(router)) { try sale(token: router) }
        #expect(throws: GaslessSale.Failure.malformed) { try sale(amount: "0") }
        #expect(throws: GaslessSale.Failure.malformed) { try sale(requestID: "0x12") }
    }
}
