import DeskAuth
import DeskChain
import DeskMoney
import DeskNet
import Foundation
import Testing

@testable import DeskFlow

/// Routes `eth_call` by `to`, not by method: `BalanceReader` fires two calls concurrently,
/// and per-method queues would answer them in scheduler order.
private final class ContractTransport: HTTPTransport, @unchecked Sendable {
    enum Reply {
        case word(String)
        case revert
        case unreachable
    }

    private let byContract: [String: Reply]
    private let gas: Reply

    init(byContract: [String: Reply], gas: Reply) {
        self.byContract = byContract.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
        self.gas = gas
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let body = request.httpBody ?? Data()
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
        let method = object["method"] as? String ?? ""
        let params = object["params"] as? [Any] ?? []

        let reply: Reply
        switch method {
        case "eth_getBalance":
            reply = gas
        case "eth_call":
            let call = params.first as? [String: Any] ?? [:]
            let to = (call["to"] as? String ?? "").lowercased()
            reply = byContract[to] ?? .revert
        default:
            reply = .unreachable
        }

        switch reply {
        case .word(let hex):
            return HTTPResponse(status: 200, body: Data(#"{"jsonrpc":"2.0","id":1,"result":"\#(hex)"}"#.utf8))
        case .revert:
            return HTTPResponse(
                status: 200,
                body: Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":3,"message":"execution reverted"}}"#.utf8))
        case .unreachable:
            return HTTPResponse(status: 503, body: Data("gateway down".utf8))
        }
    }
}

private let token = EthereumAddress(bytes: Data(hex: "a9012a055bd4e0edff8ce09f960291c09d5322dc"))!
private let exchange = EthereumAddress(bytes: Data(hex: "34b6552d57a35a1d042ccae1951bd1c370112a6f"))!
private let holder = EthereumAddress(bytes: Data(hex: "50b240678777451befd67b7e8c3b4366482ba8f9"))!

private func reader(
    ausd: ContractTransport.Reply,
    desk: ContractTransport.Reply,
    gas: ContractTransport.Reply
) throws -> BalanceReader {
    let transport = ContractTransport(
        byContract: [token.checksummed: ausd, exchange.checksummed: desk], gas: gas)
    let rpc = MonadRPC(
        configuration: try .init(url: #require(URL(string: "https://node.invalid")), chainID: 10_143),
        transport: transport)
    return BalanceReader(
        rpc: rpc,
        addresses: ExchangeAddresses(
            collateralToken: token, exchange: exchange, minimumToOpen: Money(text: "100")!))
}

private func word(_ value: UInt64) -> String {
    "0x" + String(format: "%064llx", value)
}

@Suite("Reading balances")
struct BalanceReaderTests {
    @Test("Every balance arrives when every call succeeds")
    func happyPath() async throws {
        // 1,282.18 AUSD at six decimals, and 0.19 MON at eighteen.
        let subject = try reader(
            ausd: .word(word(1_282_180_000)),
            desk: .word(word(7)),
            gas: .word("0x" + String(190_000_000_000_000_000, radix: 16)))

        let snapshot = await subject.read(for: holder)
        #expect(snapshot.walletAUSD.value?.display() == "1,282.18")
        #expect(snapshot.gas.value?.display(fractionDigits: 2) == "0.19")
        #expect(snapshot.hasDesk.value == true)
        #expect(snapshot.isTotalFailure == false)
    }

    @Test("One failed read does not blank the others")
    func failuresAreIsolated() async throws {
        let subject = try reader(
            ausd: .unreachable,
            desk: .word(word(7)),
            gas: .word("0x" + String(190_000_000_000_000_000, radix: 16)))

        let snapshot = await subject.read(for: holder)
        #expect(snapshot.walletAUSD.problem != nil)
        #expect(snapshot.gas.value?.display(fractionDigits: 2) == "0.19")
        #expect(snapshot.hasDesk.value == true)
        #expect(snapshot.isTotalFailure == false)
    }

    @Test("A revert on the account read means no desk, not an error")
    func revertIsAnAnswer() async throws {
        let subject = try reader(ausd: .word(word(0)), desk: .revert, gas: .word("0x0"))

        let snapshot = await subject.read(for: holder)
        #expect(snapshot.hasDesk == .ok(false))
        #expect(snapshot.hasDesk.problem == nil)
        #expect(snapshot.walletAUSD.value == .zero)
    }

    @Test("Everything down is reported as everything down")
    func totalFailure() async throws {
        let subject = try reader(ausd: .unreachable, desk: .unreachable, gas: .unreachable)
        let snapshot = await subject.read(for: holder)
        #expect(snapshot.isTotalFailure)
    }

    @Test("A failure sentence never carries the endpoint")
    func failureSentencesAreClean() async throws {
        let subject = try reader(ausd: .unreachable, desk: .unreachable, gas: .unreachable)
        let snapshot = await subject.read(for: holder)
        for problem in [snapshot.walletAUSD.problem, snapshot.gas.problem, snapshot.hasDesk.problem] {
            let text = try #require(problem)
            #expect(!text.contains("node.invalid"))
            #expect(!text.contains("http"))
            #expect(text.hasSuffix("."))
        }
    }

    @Test("A zero balance is a value, not an absence")
    func zeroIsNotNil() async throws {
        let subject = try reader(ausd: .word(word(0)), desk: .revert, gas: .word("0x0"))
        let snapshot = await subject.read(for: holder)
        #expect(snapshot.walletAUSD.value == .zero)
        #expect(snapshot.walletAUSD.problem == nil)
        #expect(snapshot.gas.value == .zero)
    }
}

@Suite("MON is not AUSD")
struct NativeAmountTests {
    @Test("The same word means different amounts in the two scales")
    func scalesDoNotMix() {
        let raw = Data(hex: "02a303fe4b530000")  // 0.19 × 10^18
        let asGas = NativeAmount(bigEndian: raw)
        #expect(asGas.display(fractionDigits: 2) == "0.19")
        #expect(ABIMoney.decode(raw).display() != "0.19")
    }

    @Test("A balance past UInt64 still reads correctly")
    func beyondUInt64() {
        // 25 MON = 25 × 10^18, which exceeds UInt64.max (≈1.8 × 10^19).
        var value = Int128(25)
        for _ in 0..<18 { value *= 10 }
        let bytes = NativeAmountTests.bigEndian(value)
        #expect(NativeAmount(bigEndian: bytes).display(fractionDigits: 2) == "25.00")
    }

    @Test("Rendering truncates and never rounds up")
    func truncates() {
        var value = Int128(1_999_999)
        for _ in 0..<12 { value *= 10 }
        let amount = NativeAmount(bigEndian: NativeAmountTests.bigEndian(value))
        #expect(amount.display(fractionDigits: 2) == "1.99")
        #expect(amount.display(fractionDigits: 0) == "1")
    }

    @Test("Thousands are grouped", arguments: [
        (Int128(1_234), "1,234.0000"),
        (Int128(1_000_000), "1,000,000.0000"),
        (Int128(999), "999.0000"),
    ])
    func grouping(whole: Int128, expected: String) {
        var value = whole
        for _ in 0..<18 { value *= 10 }
        #expect(NativeAmount(bigEndian: NativeAmountTests.bigEndian(value)).display() == expected)
    }

    @Test("An empty word is zero, not a crash")
    func emptyIsZero() {
        #expect(NativeAmount(bigEndian: Data()) == .zero)
        #expect(NativeAmount(bigEndian: Data()).display(fractionDigits: 2) == "0.00")
    }

    @Test("An absurd word clamps rather than wrapping")
    func clamps() {
        let enormous = Data(repeating: 0xFF, count: 32)
        let amount = NativeAmount(bigEndian: enormous)
        #expect(amount.raw == NativeAmount.maxRaw)
    }

    @Test("The ceiling is exactly ten to the thirty")
    func ceilingIsExact() {
        var expected = Int128(1)
        for _ in 0..<30 { expected *= 10 }
        // Int128(1e30) would route through a Double and land on a rounded neighbour.
        #expect(NativeAmount.maxRaw == expected)
    }

    private static func bigEndian(_ value: Int128) -> Data {
        var bytes: [UInt8] = []
        var remaining = value
        while remaining > 0 {
            bytes.insert(UInt8(truncatingIfNeeded: remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return Data(bytes)
    }
}
