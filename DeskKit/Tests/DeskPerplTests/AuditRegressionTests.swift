import DeskAuth
import DeskMoney
import DeskNet
import Foundation
import Testing

@testable import DeskPerpl

/// The 13 September audit of DeskPerpl. Every case here passed the module's own tests at
/// the time, which is why each one stays.

private func loadContext(mutating: (inout [String: Any]) -> Void = { _ in }) throws -> PerplContext {
    let url = try #require(Bundle.module.url(forResource: "Context-testnet", withExtension: "json"))
    var object = try #require(
        try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
    mutating(&object)
    return try JSONDecoder().decode(
        PerplContext.self, from: try JSONSerialization.data(withJSONObject: object))
}

@Suite("Audit: orders")
struct OrderAuditTests {
    private func btc() throws -> Market { try #require(try loadContext().market(id: 16)) }

    @Test("A close at the wrong size scale is refused, not sent a hundredth the size")
    func closeChecksScale() throws {
        // BTC sizes to five decimals. A size at three used to pass straight through, so
        // a 1.5 BTC close went out as 0.015 BTC and the position stayed open.
        let size = try #require(Size(typed: "1.500", decimals: 3))
        #expect(throws: OrderBuilder.Failure.sizeScaleMismatch) {
            try OrderBuilder.close(
                side: .long, market: try btc(), account: 7, size: size,
                slippageBps: 50, headBlock: 100, requestID: 1, frameID: 1)
        }
    }

    @Test("A limit order at price zero is refused")
    func limitRejectsZeroPrice() throws {
        // Price zero is how this venue spells marketable. A limit carrying it is a market
        // order with good-till-cancelled and no slippage bound at all.
        for raw in [Int64(0), -1, -772_458] {
            let price = try #require(Price(raw: raw, decimals: 1))
            #expect(throws: OrderBuilder.Failure.priceMustBePositive, "\(raw)") {
                try OrderBuilder.limit(
                    side: .short, market: try btc(), account: 7, price: price,
                    size: #require(Size(raw: 1500, decimals: 5)),
                    leverageHundredths: 100, headBlock: 100, requestID: 1, frameID: 1)
            }
        }
    }

    @Test("The chain head cannot overflow the version-235 wire order")
    func headBlockIsNotEncoded() throws {
        #expect(throws: Never.self) {
            try OrderBuilder.market(
                side: .long, market: try btc(), account: 7,
                size: #require(Size(raw: 1500, decimals: 5)),
                leverageHundredths: 100, slippageBps: 50,
                headBlock: .max, requestID: 1, frameID: 1)
        }
    }

    @Test("Leverage is checked against the fraction, not a truncated multiple of it")
    func fractionalLeverageCeiling() throws {
        // A 12.5x market: `initialMarginFraction / 100 * 100` rounds the ceiling down to
        // 12x and refuses leverage the venue allows.
        let market = try #require(try loadContext { object in
            var markets = object["markets"] as! [[String: Any]]
            var config = markets[0]["config"] as! [String: Any]
            config["initial_margin"] = 1250
            markets[0]["config"] = config
            object["markets"] = [markets[0]]
        }.market(id: 16))

        #expect(throws: Never.self) {
            try OrderBuilder.market(
                side: .long, market: market, account: 7,
                size: #require(Size(raw: 1500, decimals: 5)),
                leverageHundredths: 1250, slippageBps: 50,
                headBlock: 100, requestID: 1, frameID: 1)
        }
        #expect(throws: OrderBuilder.Failure.leverageOutOfRange(1251, max: 1250)) {
            try OrderBuilder.market(
                side: .long, market: market, account: 7,
                size: #require(Size(raw: 1500, decimals: 5)),
                leverageHundredths: 1251, slippageBps: 50,
                headBlock: 100, requestID: 1, frameID: 1)
        }
    }

    @Test("A maximal last-forwarded value saturates instead of killing the app")
    func requestCounterSaturates() async {
        // This seed arrives from the wallet snapshot on every connect.
        let counter = RequestCounter(lastForwarded: .max)
        #expect(await counter.take() == .max)
        let seeded = RequestCounter(lastForwarded: 40)
        await seeded.reseed(lastForwarded: .max)
        #expect(await seeded.take() == .max)
    }
}

@Suite("Audit: context")
struct ContextAuditTests {
    @Test("A scaled integer sent as a string decodes wherever it appears")
    func wireIntegersEverywhere() throws {
        // Perpl sends these as numbers while small and strings once large, per field.
        // One market crossing that threshold used to fail the entire context decode,
        // which is the app failing to start.
        let context = try loadContext { object in
            var markets = object["markets"] as! [[String: Any]]
            var state = markets[0]["state"] as! [String: Any]
            state["oi"] = "1909958"
            state["mrk"] = "767190"
            markets[0]["state"] = state
            var funding = markets[0]["funding"] as! [String: Any]
            funding["sum"] = "107377"
            markets[0]["funding"] = funding
            object["markets"] = [markets[0]]
        }
        let market = try #require(context.market(id: 16))
        #expect(market.state.openInterestRaw == 1_909_958)
        #expect(market.state.markRaw == 767_190)
        #expect(market.funding?.sumRaw == 107_377)
    }

    @Test("Margin fractions that are not fractions are refused")
    func marginBounds() throws {
        #expect(throws: (any Error).self) {
            try loadContext { object in
                var markets = object["markets"] as! [[String: Any]]
                var config = markets[0]["config"] as! [String: Any]
                config["initial_margin"] = -1
                config["maintenance_margin"] = 0
                markets[0]["config"] = config
                object["markets"] = [markets[0]]
            }.validated()
        }
    }

    @Test("A zero slippage cap is refused, because it would forbid every close")
    func slippageCapBounds() throws {
        #expect(throws: PerplContext.Invariant.slippageCapUnusable(market: 16, bps: 0)) {
            try loadContext { object in
                var markets = object["markets"] as! [[String: Any]]
                markets[0]["order_max_market_slippage_bps"] = 0
                object["markets"] = [markets[0]]
            }.validated()
        }
    }

    @Test("A head block that cannot be one is refused before it reaches an order")
    func headBlockBounds() throws {
        #expect(throws: PerplContext.Invariant.headBlockUnusable(Int64.max)) {
            try loadContext { object in
                var chain = object["chain"] as! [String: Any]
                var gas = chain["gas"] as! [String: Any]
                gas["h"] = "9223372036854775807"
                chain["gas"] = gas
                object["chain"] = chain
            }.validated()
        }
    }

    @Test("The live context still passes every invariant")
    func liveContextStillValid() throws {
        #expect(throws: Never.self) { try loadContext().validated() }
    }
}

@Suite("Audit: REST")
struct RESTAuditTests {
    @Test("A base URL with a trailing slash is refused")
    func trailingSlash() {
        // It makes every target `//v1/…` on the wire while `/v1/…` was signed, so every
        // signed call 401s and nothing says why.
        #expect(throws: PerplREST.Failure.baseURLHasTrailingSlash) {
            try PerplREST.Configuration(
                baseURL: URL(string: "https://testnet.perpl.xyz/api/")!, chainID: 10143)
        }
    }

    @Test("A skew measured earlier does not explain a later refusal")
    func staleSkewDoesNotMisdiagnose() async throws {
        let noon = 1_789_300_800.0
        let transport = RecordingTransport([
            HTTPResponse(status: 200, body: Data("{}".utf8), headers: ["Date": "Sun, 13 Sep 2026 12:00:00 GMT"]),
            HTTPResponse(status: 401, body: Data(#"{"error":"api key revoked"}"#.utf8)),
        ])
        let rest = PerplREST(
            configuration: try .testnet(retry: .none), transport: transport,
            now: { Date(timeIntervalSince1970: noon + 300) })
        await rest.adopt(.init(apiKey: APIKey("pk"), signer: PerplSigner(seed: SecureBytes(Data(repeating: 7, count: 32)))))

        _ = try await rest.signedData(try PerplEndpoint(method: .get, path: "/v1/a"))
        // The gateway's own reason survives rather than being overwritten by a five
        // minute skew measured on the previous call.
        await #expect(throws: PerplREST.Failure.unauthorized(status: 401, detail: "api key revoked")) {
            try await rest.signedData(try PerplEndpoint(method: .get, path: "/v1/b"))
        }
    }

    @Test("Ending a session forgets the clock too")
    func endSessionClearsSkew() async throws {
        let noon = 1_789_300_800.0
        let transport = RecordingTransport([
            HTTPResponse(status: 200, body: Data("{}".utf8), headers: ["Date": "Sun, 13 Sep 2026 12:00:00 GMT"])
        ])
        let rest = PerplREST(
            configuration: try .testnet(retry: .none), transport: transport,
            now: { Date(timeIntervalSince1970: noon + 300) })
        await rest.adopt(.init(apiKey: APIKey("pk"), signer: PerplSigner(seed: SecureBytes(Data(repeating: 7, count: 32)))))
        _ = try await rest.signedData(try PerplEndpoint(method: .get, path: "/v1/a"))
        #expect(await rest.clockSkewMilliseconds == 300_000)
        await rest.endSession()
        #expect(await rest.clockSkewMilliseconds == nil)
    }
}

@Suite("Audit: socket lifecycle")
struct SocketAuditTests {
    private let snapshot = #"{"mt":19,"accounts":[{"id":7}]}"#

    private func socket(_ channel: GatedChannel, heartbeat: Duration = .milliseconds(5)) -> PerplSocket {
        PerplSocket(
            url: URL(string: "wss://testnet.perpl.xyz/ws/v1/trading")!,
            chainID: 10143, makeChannel: { _ in channel }, heartbeatInterval: heartbeat,
            now: { Date(timeIntervalSince1970: 1_789_300_800) })
    }

    private func credentials() -> PerplCredentials {
        .init(apiKey: APIKey("pk"), signer: PerplSigner(seed: SecureBytes(Data(repeating: 9, count: 32))))
    }

    @Test("An order cannot be sent while the socket is still unauthenticated")
    func noSendBeforeSnapshot() async throws {
        // The gateway answers a pre-auth order by closing 3401, which the app would then
        // report as a refused key rather than its own mistake.
        let channel = GatedChannel(frames: [snapshot])
        let perpl = socket(channel)
        let connecting = Task { try await perpl.connect(credentials: credentials()) }
        try await Task.sleep(for: .milliseconds(30))

        #expect(await perpl.isConnected == false)
        let market = try #require(try loadContext().market(id: 16))
        let order = try OrderBuilder.market(
            side: .long, market: market, account: 7,
            size: #require(Size(raw: 1500, decimals: 5)),
            leverageHundredths: 100, slippageBps: 50, headBlock: 100, requestID: 1, frameID: 1)
        await #expect(throws: PerplSocket.Failure.notAuthenticated) { try await perpl.send(order) }

        channel.release()
        _ = try await connecting.value
        #expect(await perpl.isConnected)
        await perpl.disconnect()
    }

    @Test("A disconnect during the handshake is not undone by the handshake finishing")
    func disconnectDuringHandshake() async throws {
        let channel = GatedChannel(frames: [snapshot])
        let perpl = socket(channel)
        let connecting = Task { try await perpl.connect(credentials: credentials()) }
        try await Task.sleep(for: .milliseconds(30))
        await perpl.disconnect()
        channel.release()
        _ = try? await connecting.value

        #expect(await perpl.isConnected == false)
        let settled = channel.pingCount
        try await Task.sleep(for: .milliseconds(60))
        // The heartbeat used to survive, with no reference left to cancel it.
        #expect(channel.pingCount == settled)
    }

    @Test("The handshake timeout bounds when connect returns, not only when it throws")
    func timeoutActuallyReturns() async throws {
        // Cancelling a read blocked on a live socket is only a request; the group awaits
        // it on the way out. Measured at two seconds against a fifty millisecond timeout
        // before the channel was closed on the way through.
        let channel = GatedChannel(frames: [snapshot], honoursCancellation: false)
        let perpl = socket(channel)
        let start = ContinuousClock.now
        await #expect(throws: PerplSocket.Failure.handshakeTimedOut) {
            try await perpl.connect(credentials: credentials(), handshakeTimeout: .milliseconds(50))
        }
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(channel.isClosed)
    }

    @Test("A second frame stream is refused rather than splitting the first")
    func framesOnlyOnce() async throws {
        // Two readers on one socket take alternate frames, so each consumer silently
        // misses half of its own order statuses.
        let channel = GatedChannel(frames: [snapshot], open: true)
        let perpl = socket(channel, heartbeat: .seconds(60))
        _ = try await perpl.connect(credentials: credentials())
        _ = try await perpl.frames()
        await #expect(throws: PerplSocket.Failure.framesAlreadyStarted) { _ = try await perpl.frames() }
        await perpl.disconnect()
    }

    @Test("An unparseable frame is stepped over, not fatal to the session")
    func unparseableFrameSkipped() async throws {
        let channel = GatedChannel(frames: ["pong", #"{"no_mt":1}"#, snapshot], open: true)
        let perpl = socket(channel, heartbeat: .seconds(60))
        let result = try await perpl.connect(credentials: credentials())
        #expect(result.firstAccount == 7)
        await perpl.disconnect()
    }
}

/// A channel whose first read can be held open, so the window between opening a socket
/// and authenticating it is observable.
private final class GatedChannel: WebSocketChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [String]
    private var closed = false
    private var pings = 0
    private let gate = DispatchSemaphore(value: 0)
    private let open: Bool
    private let honoursCancellation: Bool

    init(frames: [String], open: Bool = false, honoursCancellation: Bool = true) {
        self.frames = frames
        self.open = open
        self.honoursCancellation = honoursCancellation
    }

    var isClosed: Bool { lock.withLock { closed } }
    var pingCount: Int { lock.withLock { pings } }

    func release() { gate.signal() }

    func send(_ text: String) async throws {}

    func receive() async throws -> String {
        if !open { await withCheckedContinuation { $0.resume(returning: gate.wait()) } }
        let next: String? = lock.withLock { frames.isEmpty ? nil : frames.removeFirst() }
        if let next { return next }
        if honoursCancellation {
            try await Task.sleep(for: .seconds(30))
        } else {
            // Ignores cancellation, the way a real read on a live socket does. Only
            // closing the channel ends it.
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline, !isClosed { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        throw SocketClosed(code: 1000, reason: "script exhausted")
    }

    func ping() async throws { lock.withLock { pings += 1 } }
    func close() { lock.withLock { closed = true }; gate.signal() }
}

private final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [HTTPResponse]
    init(_ responses: [HTTPResponse]) { queued = responses }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.withLock { queued.isEmpty ? HTTPResponse(status: 200, body: Data("{}".utf8)) : queued.removeFirst() }
    }
}

@Suite("The session owns the key")
struct SessionOwnershipTests {
    private func tradingKey() throws -> TradingKey {
        try TradingKey(seed: SecureBytes(Data(repeating: 5, count: 32)))
    }

    /// The product document's acceptance criterion, as a test: "Leaving Desk for more than
    /// twenty seconds zeroes the key, provable by the next order asking for Face ID."
    @Test("Leaving Desk past the grace stops the client signing")
    func absenceStopsSigning() async throws {
        let base = ContinuousClock.now
        let elapsed = Elapsed()
        let session = SigningSession(now: { base.advanced(by: elapsed.value) })
        try await session.open(tradingKey())
        let rest = PerplREST(configuration: try .testnet(retry: .none), transport: RecordingTransport([]))
        await rest.adopt(.init(apiKey: APIKey("pk"), session: session))

        await session.enterBackground()
        elapsed.advance(.seconds(10))
        // Inside the grace the client still signs: a quick app switch costs nothing.
        await #expect(throws: Never.self) {
            try await rest.signedData(try PerplEndpoint(method: .get, path: "/v1/a"))
        }
        elapsed.advance(.seconds(11))
        // The client holds a function, not a key, so there is nothing left to sign with.
        await #expect(throws: SigningSession.Failure.closed) {
            try await rest.signedData(try PerplEndpoint(method: .get, path: "/v1/b"))
        }
    }

    @Test("An expired session stops the client signing")
    func expiryStopsSigning() async throws {
        let base = ContinuousClock.now
        let elapsed = Elapsed()
        let session = SigningSession(lifetime: .seconds(900), now: { base.advanced(by: elapsed.value) })
        try await session.open(tradingKey())
        let rest = PerplREST(configuration: try .testnet(retry: .none), transport: RecordingTransport([]))
        await rest.adopt(.init(apiKey: APIKey("pk"), session: session))

        await #expect(throws: Never.self) {
            try await rest.signedData(try PerplEndpoint(method: .get, path: "/v1/a"))
        }
        elapsed.advance(.seconds(901))
        await #expect(throws: SigningSession.Failure.closed) {
            try await rest.signedData(try PerplEndpoint(method: .get, path: "/v1/b"))
        }
    }

    @Test("A signature made through the session still verifies")
    func sessionSignaturesAreValid() async throws {
        let session = SigningSession()
        let key = try tradingKey()
        await session.open(key)
        let credentials = PerplCredentials(apiKey: APIKey("pk"), session: session)
        let canonical = PerplCanonical.signIn(
            chainID: 10143, stamp: RequestStamp(timestampMilliseconds: 1, nonce: "n"))
        let signature = try await credentials.sign(canonical)
        #expect(try PerplSigner(seed: key.seed).verify(signature, over: canonical))
    }
}

private final class Elapsed: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Duration = .zero
    var value: Duration { lock.withLock { stored } }
    func advance(_ amount: Duration) { lock.withLock { stored += amount } }
}
