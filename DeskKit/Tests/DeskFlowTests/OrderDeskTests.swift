import DeskAuth
import DeskMoney
import DeskNet
import DeskPerpl
import Foundation
import Testing

@testable import DeskFlow

/// A channel that can be made to answer an order before `send` has returned.
///
/// That is the whole point of one of these tests: the gateway is fast enough that a
/// status frame can arrive while the send call is still unwinding, so an implementation
/// which tracks the order afterwards drops the answer.
private final class ScriptedChannel: WebSocketChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var inbound: [String]
    private var outbound: [String] = []
    private var closed = false
    /// Runs inside `send`, before it returns.
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

    @Test("An order cannot be placed before the socket has signed in")
    func mustConnectFirst() async throws {
        let subject = try desk(ScriptedChannel(inbound: [snapshot]))
        await #expect(throws: OrderDesk.Failure.notConnected) {
            _ = try await subject.place(try draft(), headBlock: 1_000)
        }
    }

    /// The trap this exists for. The gateway can answer before `send` returns, and a
    /// status frame for an untracked id is dropped — which the user experiences as an
    /// order that vanished rather than one that failed.
    @Test("The order is tracked before it is sent, not after")
    func trackedBeforeSend() async throws {
        let channel = ScriptedChannel(inbound: [snapshot])
        let subject = try desk(channel)
        try await subject.open(credentials: credentials())

        // Asked while `send` is still on the stack: the order must already be known.
        let seen = LockedBox<OrderPhase?>(nil)
        channel.duringSend = { [seen] in
            let waiter = DispatchSemaphore(value: 0)
            Task { seen.value = await subject.phase(of: 1); waiter.signal() }
            waiter.wait()
        }

        _ = try await subject.place(try draft(), headBlock: 1_000)
        #expect(seen.value == .sent)
    }

    /// A send that throws must leave nothing behind, or the next `expire` sweep reports
    /// an order the venue never received.
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

    /// `rq` must strictly increase per account; a value at or below the last forwarded one
    /// rejects with `sr: 32`. Two orders placed back to back must not share one.
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

    /// The venue refuses forwarded orders until `fw` is set, which the opening sequence
    /// does. It gets its own case because the sentence a user needs is "finish opening
    /// your desk" rather than "the order failed".
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

    /// An order whose deadline block has passed is expired rather than pending forever —
    /// the difference between a sentence and a spinner that never ends.
    @Test("An order past its deadline block expires")
    func expiry() async throws {
        let channel = ScriptedChannel(inbound: [snapshot])
        let subject = try desk(channel)
        try await subject.open(credentials: credentials())
        let frameID = try await subject.place(try draft(), headBlock: 1_000, ttlBlocks: 30)

        #expect(await subject.expire(headBlock: 1_020).isEmpty)
        #expect(await subject.expire(headBlock: 1_100) == [frameID])
    }

    /// Reconnecting reseeds from the venue's counter rather than carrying ours across,
    /// because the venue is the authority on what it last forwarded.
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

/// A tiny box so a synchronous callback can hand a value back out.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
