import Foundation
import Testing

@testable import DeskFlow

/// Every expected string here was printed by web/api/_copy.mjs for the same inputs: the server
/// rejects a grant or a request whose bytes differ from what it would write itself.
@Suite struct ServerCopyTests {
    let account = "0x50B240678777451BEfd67B7e8c3b4366482ba8F9"
    let caps = ServerCopyProtocol.Caps(
        maxMarginPerTrade: 50, maxLeverage: 10, maxOpenCopies: 5, maxOpenNotional: 1000, maxDailyLoss: 100, maxOrdersPerHour: 30)

    @Test func grantMatchesTheServer() {
        let text = ServerCopyProtocol.grantText(
            account: account, network: .testnet, serverKey: "0x" + String(repeating: "ab", count: 32),
            deviceKey: "BAAA", caps: caps, issuedAt: 1_792_089_600_123)
        #expect(text == "Desk Auto-Copy grant\nI let Desk's server copy trades for this account within these limits.\nAccount: 0x50B240678777451BEfd67B7e8c3b4366482ba8F9\nNetwork: testnet\nServer key: 0xabababababababababababababababababababababababababababababababab\nDevice key: BAAA\nMax margin per trade: 50 AUSD\nMax leverage: 10x\nMax open copies: 5\nMax open notional: 1000 AUSD\nMax daily loss: 100 AUSD\nMax orders per hour: 30\nIssued: 2026-10-15T18:40:00.123Z")
    }

    @Test func prepareMatchesTheServer() {
        #expect(ServerCopyProtocol.prepareText(account: account, network: .mainnet, issuedAt: 1_792_089_600_123)
            == "Desk Auto-Copy: prepare a server key\nAccount: 0x50B240678777451BEfd67B7e8c3b4366482ba8F9\nNetwork: mainnet\nIssued: 2026-10-15T18:40:00.123Z")
    }

    @Test func requestStringMatchesTheServer() {
        let text = ServerCopyProtocol.canonical(
            chainID: 10143, action: "rules", time: 1_792_089_600_123, nonce: "abcdefghijklmnop", body: Data(#"{"traders":{}}"#.utf8))
        #expect(text == "desk-copy\n10143\nPOST\n/api/copy/rules\n1792089600123\nabcdefghijklmnop\n146a4dce11201b1c9ad12c4a8c63d4b21477fcb60e79cb303e04baf1f7c1c288")
    }

    @Test func wholeSecondsStillCarryMilliseconds() {
        #expect(ServerCopyProtocol.iso(milliseconds: 1_792_089_600_000) == "2026-10-15T18:40:00.000Z")
    }

    @Test func thePayloadMustNameTheReportedKey() throws {
        let url = try #require(Bundle.module.url(forResource: "EnrolmentPayload", withExtension: "json"))
        let payload = try Data(contentsOf: url)
        let typed = try JSONSpan.value(of: "typed_data", in: payload)
        let vectorKey = "0x89684d872dd939e6c13b2c9d501465bdfe3546a81d32c2889dca5b6847046100"
        #expect(ServerCopyProtocol.payloadNamesKey(typedDataJSON: typed, serverKey: vectorKey))
        #expect(!ServerCopyProtocol.payloadNamesKey(typedDataJSON: typed, serverKey: "0x" + String(repeating: "11", count: 32)))
        #expect(!ServerCopyProtocol.payloadNamesKey(typedDataJSON: typed, serverKey: "0x1234"))
    }

    @Test func capsMakeRoomForWhatIsAlreadySet() {
        var rules = CopyRules()
        rules.marginPerTrade = 40
        rules.sizing = .conviction
        rules.maxLeverage = 15
        let fitted = ServerCopyProtocol.Caps.fitting(rules: [rules], guards: CopyGuards())
        #expect(fitted.maxMarginPerTrade == 80)
        #expect(fitted.maxLeverage == 15)
        #expect(fitted.allows(rules: rules))
        #expect(fitted.allows(guards: CopyGuards()))
        rules.marginPerTrade = 41
        #expect(!fitted.allows(rules: rules))
    }
}

@Suite("Spot Auto-Copy grant")
struct SpotCopyGrantTests {
    /// Printed by web/api/_spot.mjs `spotGrantText` for these inputs, lowercase addresses in.
    @Test func grantMatchesTheServer() {
        let text = SpotCopyProtocol.grantText(
            wallet: "0x8da208f0c0a36c7f11bba1a7e0b54f7900201c4b", desk: "0x515b2e45b143aed58ff7e4d583303c0e6aecba18",
            deviceKey: "BPdev", limits: .init(perTrade: 25, perDay: 100), expiry: 1_794_800_000, issuedAt: 1_792_209_000_123)
        #expect(text == "Desk Spot Auto-Copy\nI let Desk's key copy token trades for this wallet, within these limits, until the date below.\nWallet: 0x8Da208F0c0A36c7F11bBa1A7e0B54F7900201c4B\nDesk key: 0x515b2e45b143AED58Ff7e4D583303c0E6aeCBa18\nDevice key: BPdev\nMax per buy: 25 AUSD\nMax per day: 100 AUSD\nUntil: 2026-11-16T03:33:20.000Z\nIssued: 2026-10-17T03:50:00.123Z")
    }

    @Test func rulesEncodeAsTheServerReadsThem() throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SpotCopyProtocol.Rules())) as? [String: Any]
        #expect(json?["sizing"] as? String == "fixed")
        #expect(json?["slippageBps"] as? Int == 500)
        #expect(json?["maxLeaderUsd"] == nil)
    }
}
