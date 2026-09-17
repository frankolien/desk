import Testing

@testable import DeskFlow

@Suite("Position events")
struct PositionEventsTests {
    private func frame(topic: String, account: String) -> String {
        let perp = String(repeating: "0", count: 62) + "10"
        let accountWord = String(repeating: "0", count: 64 - account.count) + account
        let rest = String(repeating: "0", count: 64)
        return #"{"jsonrpc":"2.0","method":"eth_subscription","params":{"subscription":"0xab","result":{"topics":["\#(topic)"],"data":"0x\#(perp)\#(accountWord)\#(rest)"}}}"#
    }

    @Test("The account is read from the second data word of a position event")
    func readsAccount() {
        #expect(PositionEvents.account(inFrame: frame(topic: PositionEvents.topics[0], account: "f3d")) == 3901)
        #expect(PositionEvents.account(inFrame: frame(topic: PositionEvents.topics[1].uppercased(), account: "1")) == 1)
    }

    @Test("Other events, subscription answers and malformed data are ignored")
    func ignoresNoise() {
        #expect(PositionEvents.account(inFrame: frame(topic: "0xb5858652", account: "f3d")) == nil)
        #expect(PositionEvents.account(inFrame: #"{"jsonrpc":"2.0","id":1,"result":"0xecb3"}"#) == nil)
        #expect(PositionEvents.account(inFrame: "not json") == nil)
        #expect(PositionEvents.account(inFrame: frame(topic: PositionEvents.topics[0], account: "1" + String(repeating: "0", count: 20))) == nil)
    }

    @Test("The subscription asks for every position event on the exchange")
    func subscription() {
        let request = PositionEvents.subscription(exchange: "0x34B6552d57a35a1D042CcAe1951BD1C370112a6F")
        #expect(request.contains("eth_subscribe"))
        #expect(PositionEvents.topics.allSatisfy { request.contains($0) })
    }
}
