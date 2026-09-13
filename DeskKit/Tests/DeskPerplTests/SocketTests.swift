import DeskAuth
import DeskNet
import Foundation
import Testing

@testable import DeskPerpl

private final class FakeChannel: WebSocketChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var inbound: [Result<String, any Error>]
    private var outbound: [String] = []
    private var closed = false
    private var pings = 0

    init(_ inbound: [Result<String, any Error>]) { self.inbound = inbound }

    convenience init(frames: [String], then error: (any Error)? = nil) {
        self.init(frames.map { .success($0) } + (error.map { [.failure($0)] } ?? []))
    }

    var sent: [String] { lock.withLock { outbound } }
    var isClosed: Bool { lock.withLock { closed } }
    var pingCount: Int { lock.withLock { pings } }

    func send(_ text: String) async throws { lock.withLock { outbound.append(text) } }

    func receive() async throws -> String {
        let next: Result<String, any Error>? = lock.withLock { inbound.isEmpty ? nil : inbound.removeFirst() }
        guard let next else {
            // An exhausted script must not look like a live-but-quiet socket, or a test
            // that never receives its frame hangs instead of failing.
            try await Task.sleep(for: .seconds(30))
            throw SocketClosed(code: 1000, reason: "script exhausted")
        }
        return try next.get()
    }

    func ping() async throws { lock.withLock { pings += 1 } }
    func close() { lock.withLock { closed = true } }
}

private func signer() -> PerplSigner { PerplSigner(seed: SecureBytes(Data(repeating: 9, count: 32))) }
private func credentials() -> PerplCredentials { .init(apiKey: APIKey("pk_socket"), signer: signer()) }

private func socket(_ channel: FakeChannel) -> PerplSocket {
    PerplSocket(
        url: URL(string: "wss://testnet.perpl.xyz/ws/v1/trading")!,
        chainID: 10143,
        makeChannel: { _ in channel },
        heartbeatInterval: .milliseconds(5),
        now: { Date(timeIntervalSince1970: 1_789_300_800) })
}

private let snapshotFrame = #"{"mt":19,"accounts":[{"id":7},{"id":8}]}"#

private func btcMarket() throws -> Market {
    let url = try #require(Bundle.module.url(forResource: "Context-testnet", withExtension: "json"))
    let context = try JSONDecoder().decode(PerplContext.self, from: Data(contentsOf: url))
    return try #require(context.market(id: 16))
}

@Suite("Socket handshake")
struct SocketHandshakeTests {
    @Test("Sign-in is the first thing written, and it verifies against the canonical string")
    func signInFrameIsFirst() async throws {
        let channel = FakeChannel(frames: [snapshotFrame])
        let perpl = socket(channel)
        let snapshot = try await perpl.connect(credentials: credentials())
        #expect(snapshot.firstAccount == 7)

        let first = try #require(channel.sent.first)
        struct Sent: Decodable { let mt: Int; let chain_id: UInt64; let api_key: String; let timestamp: String; let nonce: String; let signature: String }
        let frame = try JSONDecoder().decode(Sent.self, from: Data(first.utf8))
        #expect(frame.mt == 29)
        #expect(frame.chain_id == 10143)
        #expect(frame.api_key == "pk_socket")

        let stamp = RequestStamp(timestampMilliseconds: try #require(Int64(frame.timestamp)), nonce: frame.nonce)
        let canonical = PerplCanonical.signIn(chainID: 10143, stamp: stamp)
        #expect(try signer().verify(frame.signature, over: canonical))
        await perpl.disconnect()
    }

    @Test("Frames before the snapshot are read past, not mistaken for it")
    func skipsUntilSnapshot() async throws {
        let channel = FakeChannel(frames: [#"{"mt":24,"oid":1}"#, #"{"mt":3,"code":0}"#, snapshotFrame])
        let perpl = socket(channel)
        #expect(try await perpl.connect(credentials: credentials()).accounts.count == 2)
        await perpl.disconnect()
    }

    @Test("A refused sign-in is named, not reported as a dropped network")
    func signInRefused() async throws {
        let channel = FakeChannel(frames: [], then: SocketClosed(code: 3401, reason: "unauthorized"))
        let perpl = socket(channel)
        await #expect(throws: PerplSocket.Failure.signInRefused(reason: "unauthorized")) {
            try await perpl.connect(credentials: credentials())
        }
        #expect(channel.isClosed)
        #expect(await perpl.isConnected == false)
    }

    @Test("The ten-second idle close is its own diagnosis")
    func idleTimeout() async throws {
        let channel = FakeChannel(frames: [], then: SocketClosed(code: 1008, reason: "idle timeout"))
        await #expect(throws: PerplSocket.Failure.idleTimeout) {
            try await socket(channel).connect(credentials: credentials())
        }
    }

    @Test("Any other close carries its code through")
    func otherClose() async throws {
        let channel = FakeChannel(frames: [], then: SocketClosed(code: 1011, reason: "internal error"))
        await #expect(throws: PerplSocket.Failure.closed(code: 1011, reason: "internal error")) {
            try await socket(channel).connect(credentials: credentials())
        }
    }

    @Test("A silent gateway gives up rather than hanging the sign-in screen")
    func handshakeTimesOut() async throws {
        let channel = FakeChannel(frames: [])
        let perpl = socket(channel)
        await #expect(throws: PerplSocket.Failure.handshakeTimedOut) {
            try await perpl.connect(credentials: credentials(), handshakeTimeout: .milliseconds(50))
        }
        #expect(channel.isClosed)
    }

    @Test("Connecting twice is refused rather than leaking the first socket")
    func doubleConnect() async throws {
        let channel = FakeChannel(frames: [snapshotFrame])
        let perpl = socket(channel)
        try await perpl.connect(credentials: credentials())
        await #expect(throws: PerplSocket.Failure.alreadyConnected) {
            try await perpl.connect(credentials: credentials())
        }
        await perpl.disconnect()
    }
}

@Suite("Socket traffic")
struct SocketTrafficTests {
    @Test("An order cannot be sent before the handshake")
    func orderBeforeConnect() async throws {
        let perpl = socket(FakeChannel(frames: []))
        let market = try btcMarket()
        let order = try OrderBuilder.market(
            side: .long, market: market, account: 7, size: #require(market.size(1_480)),
            leverageHundredths: 200, slippageBps: 50, headBlock: 100, requestID: 1, frameID: 1)
        await #expect(throws: PerplSocket.Failure.notConnected) { try await perpl.send(order) }
    }

    @Test("A sent order is the encoded message-22 frame")
    func orderIsSent() async throws {
        let channel = FakeChannel(frames: [snapshotFrame])
        let perpl = socket(channel)
        try await perpl.connect(credentials: credentials())
        let market = try btcMarket()
        let order = try OrderBuilder.market(
            side: .long, market: market, account: 7, size: #require(market.size(1_480)),
            leverageHundredths: 200, slippageBps: 50, headBlock: 100, requestID: 42, frameID: 1)
        try await perpl.send(order)

        let body = try #require(channel.sent.last)
        let frame = try InboundFrame(payload: Data(body.utf8))
        #expect(frame.kind == .order)
        struct Sent: Decodable { let mt: Int; let acc: UInt32; let rq: Int64; let ms: Int; let fl: Int }
        let sent = try JSONDecoder().decode(Sent.self, from: Data(body.utf8))
        #expect((sent.mt, sent.acc, sent.rq, sent.ms, sent.fl) == (22, 7, 42, 50, 4))
        await perpl.disconnect()
    }

    @Test("The frame stream yields what arrives and ends with the close mapped")
    func frameStream() async throws {
        let channel = FakeChannel(
            frames: [snapshotFrame, #"{"mt":3,"sn":1,"code":0}"#, #"{"mt":3,"sn":2,"code":1,"sr":34}"#],
            then: SocketClosed(code: 3401, reason: "unauthorized"))
        let perpl = socket(channel)
        try await perpl.connect(credentials: credentials())

        var statuses: [OrderStatus] = []
        var thrown: (any Error)?
        do {
            for try await frame in try await perpl.frames() where frame.kind == .orderStatus {
                statuses.append(try frame.decode(OrderStatus.self))
            }
        } catch {
            thrown = error
        }
        #expect(statuses.count == 2)
        #expect(statuses[0].isAccepted)
        #expect(statuses[1].isAccepted == false)
        // 34 is order forwarding still disabled on the account: an opening-sequence bug,
        // not a trading one, and the only field that says so.
        #expect(statuses[1].subReason == 34)
        #expect(thrown as? PerplSocket.Failure == .signInRefused(reason: "unauthorized"))
        await perpl.disconnect()
    }

    @Test("An unmodelled frame is carried, not rejected")
    func unknownFrame() throws {
        let frame = try InboundFrame(payload: Data(#"{"mt":4242,"whatever":{"deeply":[1,2,3]}}"#.utf8))
        #expect(frame.messageType == 4242)
        #expect(frame.kind == nil)
    }

    @Test("The socket is kept warm")
    func heartbeat() async throws {
        let channel = FakeChannel(frames: [snapshotFrame])
        let perpl = socket(channel)
        try await perpl.connect(credentials: credentials())
        try await Task.sleep(for: .milliseconds(60))
        #expect(channel.pingCount > 0)
        await perpl.disconnect()
        let settled = channel.pingCount
        try await Task.sleep(for: .milliseconds(40))
        #expect(channel.pingCount == settled)
    }
}
