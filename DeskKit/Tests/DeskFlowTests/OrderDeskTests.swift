import DeskAuth
import DeskMoney
import DeskNet
import DeskPerpl
import Foundation
import Testing

@testable import DeskFlow

/// A channel that can answer an order before `send` has returned, as the real gateway
/// can; an order tracked only after `send` would drop that answer.
private final class ScriptedChannel: WebSocketChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var inbound: [String]
    private var outbound: [String] = []
    private var closed = false
    var duringSend: (@Sendable () -> Void)?
    var sendFails: (any Error)?

    init(inbound: [String]) { self.inbound = inbound }

    var sent: [String] { lock.withLock { outbound } }
    var isClosed: Bool { lock.withLock { closed } }

    func send(_ text: String) async throws {
        duringSend?()
        if let sendFails, text.contains("\"mt\":22") { throw sendFails }
        lock.withLock { outbound.append(text) }
    }

    func receive() async throws -> String {
        let next: String? = lock.withLock { inbound.isEmpty ? nil : inbound.removeFirst() }
        guard let next else {
            try await Task.sleep(for: .seconds(30))
            throw SocketClosed(code: 1000, reason: "script exhausted")
        }
        return next
    }

    func ping() async throws {}
    func close() { lock.withLock { closed = true } }
}

private struct Rejected: Error, Equatable {}

private let snapshot = #"{"mt":19,"accounts":[{"id":7}]}"#
private func snapshot(lastForwarded: Int64) -> String {
    #"{"mt":19,"accounts":[{"id":7,"lfr":\#(lastForwarded)}]}"#
}

private func market() throws -> Market {
    let url = try #require(Bundle.module.url(forResource: "Context-testnet", withExtension: "json"))
    let context = try JSONDecoder().decode(PerplContext.self, from: Data(contentsOf: url))
    return try #require(context.market(id: 16))
}

private func market(id: UInt32) throws -> Market {
    let url = try #require(Bundle.module.url(forResource: "Context-testnet", withExtension: "json"))
    let context = try JSONDecoder().decode(PerplContext.self, from: Data(contentsOf: url))
    return try #require(context.market(id: id))
}

private func credentials() -> PerplCredentials {
    .init(apiKey: APIKey("pk_test"), signer: PerplSigner(seed: SecureBytes(Data(repeating: 9, count: 32))))
}

private func desk(_ channel: ScriptedChannel) throws -> OrderDesk {
    let url = try #require(URL(string: "wss://testnet.perpl.xyz/ws/v1/trading"))
    return OrderDesk(
        socket: PerplSocket(
            url: url,
            chainID: 10143,
            makeChannel: { _ in channel },
            heartbeatInterval: .seconds(30),
            now: { Date(timeIntervalSince1970: 1_789_300_800) }),
        market: try market())
}

private func draft(_ side: Side = .long) throws -> OrderDesk.Draft {
    let config = try market().config
    return OrderDesk.Draft(
        side: side,
        size: try #require(Size(raw: 1_000, decimals: config.sizeDecimals)),
        leverageHundredths: 300,
        slippageBps: 50)
}

private func position(side: Int = 1, size: Int64 = 1_000, id: Int64 = 99) throws -> PerplPosition {
    let body = #"{"mkt":16,"acc":7,"pid":"\#(id)","sd":\#(side),"c":"1000000","ep":700000,"s":"\#(size)","lv":500,"st":1}"#
    return try JSONDecoder().decode(PerplPosition.self, from: Data(body.utf8))
}

@Suite("Sending an order")
struct OrderDeskTests {
    @Test("The account is selected for the market's exchange instance")
    func selectsMatchingInstanceAccount() async throws {
        let channel = ScriptedChannel(inbound: [
            #"{"mt":19,"as":[{"id":99,"in":77,"lfr":900},{"id":7,"in":12,"lfr":41}]}"#
        ])
        let subject = try desk(channel)
        try await subject.open(credentials: credentials())
        _ = try await subject.place(try draft(), headBlock: 1_000)

        let order = try #require(channel.sent.first { $0.contains("\"mt\":22") })
        let json = try #require(JSONSerialization.jsonObject(with: Data(order.utf8)) as? [String: Any])
        #expect(json["acc"] as? Int == 7)
        #expect(json["rq"] as? Int == 42)
    }

    @Test("One desk sends on another market of its exchange with the same request counter")
    func placesOnAnotherMarket() async throws {
        let channel = ScriptedChannel(inbound: [snapshot(lastForwarded: 41)])
        let subject = try desk(channel)
        try await subject.open(credentials: credentials())
        let url = try #require(Bundle.module.url(forResource: "Context-testnet", withExtension: "json"))
        let eth = try #require(try JSONDecoder().decode(PerplContext.self, from: Data(contentsOf: url)).market(id: 32))
        _ = try await subject.place(try draft(), headBlock: 1_000)
        _ = try await subject.place(
            OrderDesk.Draft(side: .short, size: try #require(eth.size(10)), leverageHundredths: 200, slippageBps: 50),
            headBlock: 1_000, in: eth)

        let orders = try channel.sent.filter { $0.contains("\"mt\":22") }.map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(orders.map { $0["mkt"] as? Int } == [16, 32])
        #expect(orders.map { $0["rq"] as? Int } == [42, 43])
    }

    @Test("An order cannot be placed before the socket has signed in")
    func mustConnectFirst() async throws {
        let subject = try desk(ScriptedChannel(inbound: [snapshot]))
        await #expect(throws: OrderDesk.Failure.notConnected) {
            _ = try await subject.place(try draft(), headBlock: 1_000)
        }
    }

    @Test("The order is tracked before it is sent, not after")
    func trackedBeforeSend() async throws {
        let channel = ScriptedChannel(inbound: [snapshot])
        let subject = try desk(channel)
        try await subject.open(credentials: credentials())

        let seen = LockedBox<OrderPhase?>(nil)
        channel.duringSend = { [seen] in
            let waiter = DispatchSemaphore(value: 0)
            Task { seen.value = await subject.phase(of: 1); waiter.signal() }
            waiter.wait()
        }

        _ = try await subject.place(try draft(), headBlock: 1_000)
        #expect(seen.value == .sent)
    }

    @Test("A failed send forgets the order it could not send")
    func failedSendForgets() async throws {
        let channel = ScriptedChannel(inbound: [snapshot])
        channel.sendFails = Rejected()
        let subject = try desk(channel)
        try await subject.open(credentials: credentials())

        await #expect(throws: Rejected.self) {
            _ = try await subject.place(try draft(), headBlock: 1_000)
        }
        #expect(await subject.phase(of: 1) == nil)
    }

    @Test("Request ids strictly increase across orders")
    func requestIdsIncrease() async throws {
        let channel = ScriptedChannel(inbound: [snapshot(lastForwarded: 41)])
        let subject = try desk(channel)
        try await subject.open(credentials: credentials())

        _ = try await subject.place(try draft(), headBlock: 1_000)
        _ = try await subject.place(try draft(.short), headBlock: 1_000)

        let orders = channel.sent.filter { $0.contains("\"mt\":22") }
        let ids = orders.compactMap { body -> Int64? in
            guard let data = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return (object["rq"] as? NSNumber)?.int64Value
        }
        #expect(ids.count == 2)
        #expect(ids == [42, 43], "seeded from lastForwarded 41 and strictly increasing")
    }

    @Test("stop loss and take profit are linked to the opening request")
    func linkedProtection() async throws {
        let channel = ScriptedChannel(inbound: [snapshot(lastForwarded: 41)])
        let subject = try desk(channel)
        try await subject.open(credentials: credentials())
        let config = try market().config
        let protected = OrderDesk.Draft(
            side: .long,
            size: try #require(Size(raw: 1_000, decimals: config.sizeDecimals)),
            leverageHundredths: 500,
            slippageBps: 50,
            protection: .init(
                stopLoss: try #require(Price(selling: "64000", decimals: config.priceDecimals)),
                takeProfit: try #require(Price(buying: "80000", decimals: config.priceDecimals))))

        _ = try await subject.place(protected, headBlock: 1_000)

        let bodies = channel.sent.filter { $0.contains("\"mt\":22") }
        let orders = try bodies.map { body in
            try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        }
        #expect(orders.count == 3)
        #expect(orders.map { $0["rq"] as? Int } == [42, 43, 44])
        #expect(orders[1]["tr"] as? Int == 42)
        #expect(orders[2]["tr"] as? Int == 42)
        #expect(orders[1]["tpc"] as? Int == 4)
        #expect(orders[2]["tpc"] as? Int == 3)
        #expect(orders[1]["t"] as? Int == 3)
        #expect(orders[2]["t"] as? Int == 3)
    }

    @Test("A partial close is reduce-only and uses only the requested size")
    func partialClose() async throws {
        let channel = ScriptedChannel(inbound: [snapshot(lastForwarded: 41)])
        let subject = try desk(channel)
        try await subject.open(credentials: credentials())
        let config = try market().config
        let half = try #require(Size(raw: 500, decimals: config.sizeDecimals))

        _ = try await subject.closePosition(
            try position(), size: half, slippageBps: 50, headBlock: 1_000)

        let body = try #require(channel.sent.first { $0.contains("\"mt\":22") })
        let order = try #require(
            JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect(order["t"] as? Int == 3)
        #expect(order["s"] as? Int == 500)
        #expect(order["rq"] as? Int == 42)
    }

    @Test("Protection for an open position links both triggers to its position id")
    func protectsExistingPosition() async throws {
        let channel = ScriptedChannel(inbound: [snapshot(lastForwarded: 41)])
        let subject = try desk(channel)
        try await subject.open(credentials: credentials())
        let config = try market().config

        try await subject.protectPosition(
            try position(),
            stopLoss: try #require(Price(selling: "64000", decimals: config.priceDecimals)),
            takeProfit: try #require(Price(buying: "80000", decimals: config.priceDecimals)),
            slippageBps: 50)

        let orders = try channel.sent.filter { $0.contains("\"mt\":22") }.map { body in
            try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        }
        #expect(orders.count == 2)
        #expect(orders.map { $0["rq"] as? Int } == [42, 43])
        #expect(orders.map { $0["lp"] as? Int } == [99, 99])
        #expect(orders.map { $0["tpc"] as? Int } == [4, 3])
        #expect(orders.allSatisfy { $0["tr"] == nil })
        #expect(orders.allSatisfy { $0["t"] as? Int == 3 })
    }

    @Test("Forwarding not yet allowed is its own answer")
    func forwardingRefused() async throws {
        let channel = ScriptedChannel(inbound: [snapshot])
        let subject = try desk(channel)
        try await subject.open(credentials: credentials())
        await subject.noteForwarding(false)

        await #expect(throws: OrderDesk.Failure.forwardingNotAllowed) {
            _ = try await subject.place(try draft(), headBlock: 1_000)
        }
    }

    /// `mt: 3` with `code: 0` means the gateway took it, not that it filled. A screen that
    /// reads it as a fill tells the user they hold a position they do not.
    @Test("A forwarded acknowledgement is not a fill")
    func forwardedIsNotSettled() async throws {
        let channel = ScriptedChannel(inbound: [snapshot])
        let subject = try desk(channel)
        try await subject.open(credentials: credentials())
        let frameID = try await subject.place(try draft(), headBlock: 1_000)

        let forwarded = try InboundFrame(payload: Data(#"{"mt":3,"sn":\#(frameID),"code":0}"#.utf8))
        _ = await subject.apply(forwarded)

        let phase = await subject.phase(of: frameID)
        #expect(phase == .forwarded)
        #expect(phase?.hasReachedTheBook == false)
    }

    @Test("Only an update settles an order")
    func updateSettles() async throws {
        let channel = ScriptedChannel(inbound: [snapshot])
        let subject = try desk(channel)
        try await subject.open(credentials: credentials())
        let frameID = try await subject.place(try draft(), headBlock: 1_000)

        _ = await subject.apply(try InboundFrame(payload: Data(#"{"mt":24,"sn":\#(frameID)}"#.utf8)))
        #expect(await subject.phase(of: frameID)?.hasReachedTheBook == true)
    }

    @Test("An order past its deadline block expires, after Perpl's retry window as well as its lifetime")
    func expiry() async throws {
        let channel = ScriptedChannel(inbound: [snapshot])
        let subject = try desk(channel)
        try await subject.open(credentials: credentials())
        let frameID = try await subject.place(try draft(), headBlock: 1_000, ttlBlocks: 30)

        // The fixture's market lives 20 blocks and is retried for 22.
        #expect(await subject.deadline(of: frameID) == 1_022)
        #expect(await subject.expire(headBlock: 1_022).isEmpty)
        #expect(await subject.expire(headBlock: 1_023) == [frameID])
    }

    @Test("Switching market keeps the socket, the orders being followed and the numbering")
    func retargetKeepsOrders() async throws {
        let channel = ScriptedChannel(inbound: [snapshot])
        let subject = try desk(channel)
        try await subject.open(credentials: credentials())
        let first = try await subject.place(try draft(), headBlock: 1_000)

        #expect(await subject.retarget(try market(id: 32)))
        #expect(await subject.phase(of: first) != nil, "the BTC order is still followed")
        #expect(await subject.upcomingFrameID == first + 1)
    }

    @Test("A new desk can continue an earlier desk's numbering")
    func continuesNumbering() async throws {
        let channel = ScriptedChannel(inbound: [snapshot])
        let url = try #require(URL(string: "wss://testnet.perpl.xyz/ws/v1/trading"))
        let subject = OrderDesk(
            socket: PerplSocket(
                url: url, chainID: 10143, makeChannel: { _ in channel },
                heartbeatInterval: .seconds(30), now: { Date(timeIntervalSince1970: 1_789_300_800) }),
            market: try market(), firstFrameID: 40)
        try await subject.open(credentials: credentials())
        #expect(try await subject.place(try draft(), headBlock: 1_000) == 40)
    }

    @Test("Reconnecting reseeds the request counter upward")
    func reseedOnReconnect() async throws {
        let channel = ScriptedChannel(inbound: [snapshot])
        let subject = try desk(channel)
        try await subject.open(credentials: credentials())
        _ = try await subject.place(try draft(), headBlock: 1_000)
        await subject.close()

        let second = ScriptedChannel(inbound: [snapshot(lastForwarded: 500)])
        // A fresh desk connects to a venue snapshot that is already further along.
        let reopened = try desk(second)
        try await reopened.open(credentials: credentials())
        _ = try await reopened.place(try draft(), headBlock: 1_000)

        let body = try #require(second.sent.first { $0.contains("\"mt\":22") })
        #expect(body.contains("\"rq\":501"))
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
