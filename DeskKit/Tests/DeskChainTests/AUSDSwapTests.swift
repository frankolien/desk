import DeskAuth
import DeskMoney
import DeskNet
import Foundation
import Testing
@testable import DeskChain

@Suite("AUSD swap")
struct AUSDSwapTests {
    let fiveHundred = NativeAmount(decimalText: "500")!
    let minimum = Money(text: "12.157366")!
    let holder = "0x0000000000001ff3684f28c67538d4d072c22734"
    // The head of a live 0x quote, 500 MON to AUSD on Monad, 24 September 2026: `exec`
    // naming the settler, the native token, the amount, then an opaque route.
    let quotedData = "0x2213bc0b"
        + "0000000000000000000000002e73afeb01595831a67e9e1a56e193b93331b8c7"
        + "0000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000001b1ae4d6e2ef5000"
        + String(repeating: "ab", count: 32 * 3)

    private func swap(
        chainID: UInt64 = 143, to: String? = nil, data: String? = nil,
        value: String = "500000000000000000000", amount: NativeAmount? = nil, minimum: Money? = nil
    ) throws -> AUSDSwap {
        try AUSDSwap(chainID: chainID, to: to ?? holder, data: data ?? quotedData, value: value,
                     amount: amount ?? fiveHundred, minimumOut: minimum ?? self.minimum)
    }

    @Test("a live quote's transaction is accepted, in any address case")
    func accepts() throws {
        let checked = try swap(to: "0x0000000000001fF3684f28c67538d4D072C22734")
        #expect(checked.value == fiveHundred)
        #expect(checked.minimumOut == minimum)
        #expect(checked.data.prefix(4) == Data([0x22, 0x13, 0xbc, 0x0b]))
    }

    @Test("another chain is refused")
    func chain() {
        #expect(throws: AUSDSwap.Failure.wrongChain(10143)) { try swap(chainID: 10143) }
    }

    @Test("any other contract is refused, including Relay's depository")
    func contract() {
        #expect(throws: AUSDSwap.Failure.self) { try swap(to: "0x4cd00e387622c35bddb9b4c962c136462338bc31") }
        #expect(throws: AUSDSwap.Failure.self) { try swap(to: "0x2e73afeb01595831a67e9e1a56e193b93331b8c7") }
    }

    @Test("a different call to the holder is refused")
    func call() {
        let transfer = "0xa9059cbb" + quotedData.dropFirst(10)
        #expect(throws: AUSDSwap.Failure.unexpectedCall) { try swap(data: String(transfer)) }
    }

    @Test("calldata too short to be an exec is refused")
    func short() {
        #expect(throws: AUSDSwap.Failure.malformed) { try swap(data: "0x2213bc0b00") }
    }

    @Test("a value other than the typed amount is refused", arguments: [
        "500000000000000000001", "0x1b1ae4d6e2ef5000", "", "0",
    ])
    func amount(value: String) {
        #expect(throws: AUSDSwap.Failure.self) { try swap(value: value) }
    }

    @Test("a quote promising nothing back is refused")
    func nothingBack() {
        #expect(throws: AUSDSwap.Failure.malformed) { try swap(minimum: .zero) }
    }
}

private final class OneShotTransport: HTTPTransport, @unchecked Sendable {
    let body: String
    private(set) var request: [String: Any]?
    init(_ body: String) { self.body = body }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        self.request = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        return HTTPResponse(status: 200, body: Data(body.utf8))
    }
}

@Suite("Simulation")
struct SimulationTests {
    let wallet = EthereumAddress(bytes: Data(hex: "03508bb71268bba25ecacc8f620e01866650532c"))!
    let token = EthereumAddress(bytes: Data(hex: "00000000efe302beaa2b3e6e1b18d08d69a9012a"))!

    @Test("one block of calls goes out as eth_simulateV1 and each result comes back in order")
    func roundTrip() async throws {
        let transport = OneShotTransport("""
        {"jsonrpc":"2.0","id":1,"result":[{"number":"0x1","calls":[
          {"status":"0x1","returnData":"0x0000000000000000000000000000000000000000000000000000000000989680","gasUsed":"0x5208"},
          {"status":"0x0","returnData":"0x","error":{"code":-32000,"message":"execution reverted"}}
        ]}]}
        """)
        let rpc = MonadRPC(configuration: try .mainnet(), transport: transport)
        let results = try await rpc.simulate([
            SimulatedCall(to: token, data: try Calldata.balanceOf(wallet)),
            SimulatedCall(from: wallet, to: token, data: Data([0xde, 0xad]), value: Data([0x01])),
        ])
        #expect(results.count == 2)
        #expect(results[0].succeeded)
        #expect(results[0].returnData.count == 32)
        #expect(!results[1].succeeded)

        let request = try #require(transport.request)
        #expect(request["method"] as? String == "eth_simulateV1")
        let params = try #require(request["params"] as? [Any])
        let block = try #require(params.first as? [String: Any])
        #expect(block["validation"] as? Bool == false)
        let calls = try #require(((block["blockStateCalls"] as? [[String: Any]])?.first?["calls"]) as? [[String: Any]])
        #expect(calls.count == 2)
        #expect(calls[0]["from"] == nil)
        #expect(calls[1]["value"] as? String == "0x1")
        #expect(params.last as? String == "latest")
    }

    @Test("a block with the wrong number of results is refused rather than misread")
    func shortBlock() async throws {
        let transport = OneShotTransport(#"{"jsonrpc":"2.0","id":1,"result":[{"calls":[{"status":"0x1","returnData":"0x"}]}]}"#)
        let rpc = MonadRPC(configuration: try .mainnet(), transport: transport)
        await #expect(throws: MonadRPC.Failure.malformedResponse("eth_simulateV1")) {
            try await rpc.simulate([
                SimulatedCall(to: token, data: Data()), SimulatedCall(to: token, data: Data()),
            ])
        }
    }
}
