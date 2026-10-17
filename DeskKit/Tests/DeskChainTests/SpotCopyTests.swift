import DeskAuth
import Foundation
import Testing
@testable import DeskChain

/// Every value here was printed by the server's own builders (web/copyd/spot-chain.mjs `batchFor`,
/// viem's `hashTypedData` and `hashAuthorization`), so the phone and the server can't drift.
@Suite("Spot Auto-Copy batches")
struct SpotCopyTests {
    let wallet = "0x8Da208F0c0A36c7F11bBa1A7e0B54F7900201c4B"
    let desk = "0x515b2e45b143AED58Ff7e4D583303c0E6aeCBa18"
    let hook = "0xDe5C0000000000000000000000000000dC0B501e"
    let expiry: UInt64 = 1_794_800_000
    let deadline: UInt64 = 1_792_210_000

    func hex(_ data: Data) -> String { "0x" + data.map { String(format: "%02x", $0) }.joined() }

    @Test func keyHashIsCaliburs() throws {
        #expect(hex(try SpotCopy.keyHash(desk: desk)) == "0x5dc18ac5694588aca5ee5c1af55c93ae042d2db4305c6448125afcc5977325a5")
    }

    @Test func setupMatchesTheServer() throws {
        let calls = try SpotCopy.setupCalls(desk: desk, hook: hook, expiry: expiry, perTrade: 25, perDay: 100)
        #expect(hex(calls[0].data) == "0x30b1fa3b0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000020000000000000000000000000515b2e45b143aed58ff7e4d583303c0e6aecba18")
        #expect(hex(calls[1].data) == "0xa58bb84a5dc18ac5694588aca5ee5c1af55c93ae042d2db4305c6448125afcc5977325a500000000000000006afa7980de5c0000000000000000000000000000dc0b501e")
        #expect(hex(calls[2].data) == "0xda6f39da5dc18ac5694588aca5ee5c1af55c93ae042d2db4305c6448125afcc5977325a500000000000000000000000000000000000000000000000000000000017d78400000000000000000000000000000000000000000000000000000000005f5e100")
        let typed = SpotCopy.batchTypedData(wallet: wallet, calls: calls, nonce: "0", deadline: deadline, executor: desk)
        #expect(hex(try EIP712.digest(typed)) == "0x6558744d8764276b7988bc36ef93fe51bda37e33e0d3faef141da2301635558b")
    }

    @Test func limitsAndRevokeMatchTheServer() throws {
        let limits = try SpotCopy.limitCalls(desk: desk, hook: hook, expiry: expiry, perTrade: 25, perDay: 100)
        #expect(hex(try EIP712.digest(SpotCopy.batchTypedData(wallet: wallet, calls: limits, nonce: "0", deadline: deadline, executor: desk)))
            == "0x9c121ad7c558f95439ea26aa3b01239b1759536d5f2769057a4b51d581b1f800")
        let revoke = try SpotCopy.revokeCalls(desk: desk)
        #expect(hex(try EIP712.digest(SpotCopy.batchTypedData(wallet: wallet, calls: revoke, nonce: "0", deadline: deadline, executor: desk)))
            == "0xcb9be0bdd1c4fddda566813bf75892c6735a8f767cb9578bad03c8f7e6c320ad")
    }

    @Test func authorizationMatchesViem() {
        #expect(hex(SpotCopy.authorizationDigest(nonce: 7)) == "0x66817b91c66f3f2cac54494875754d2db0c8b8bbe2cb1625c49382f5854b29e2")
    }

    @Test func aHookWithoutTheCallbackBitsIsRefused() {
        #expect(throws: SpotCopy.Failure.self) {
            try SpotCopy.setupCalls(desk: desk, hook: "0xDe5C0000000000000000000000000000dC0B501f", expiry: expiry, perTrade: 25, perDay: 100)
        }
    }
}
