import DeskMoney
import DeskPerpl
import Foundation

/// The one place an order goes through.
///
/// Every piece of this already existed — the socket, the builder, the tracker, the request
/// counter — and none of them were joined up, so the ticket's confirm button dismissed a
/// sheet. What was missing is the thing that knows the order of operations, and the order
/// of operations is where this protocol is unforgiving:
///
///   1. `rq` must strictly increase per account and is seeded from the wallet snapshot on
///      every connect. A value at or below the last forwarded one rejects with `sr: 32`,
///      so the counter is reseeded on reconnect rather than carried across one.
///   2. An order must be handed to the tracker **before** it is sent. The gateway can
///      answer faster than the send call returns, and a status frame arriving for an
///      untracked id is dropped — which presents to the user as an order that vanished.
///   3. `mt: 3` with `code: 0` means forwarded, not filled. Only `mt: 24` settles
///      anything. The tracker enforces that; this type must not second-guess it.
///
/// An actor because the socket, the counter and the tracker have to move together. Two
/// concurrent submissions racing for request ids is exactly the bug that produces `sr: 32`
/// on the second one.
public actor OrderDesk {
    public enum Event: Sendable, Hashable {
        case account(PerplAccount)
        case positions([PerplPosition])
        case order(frameID: Int64, phase: OrderPhase)
    }
    public enum Failure: Error, Sendable, Equatable {
        /// No enrolled key, so nothing can be signed. The honest state before enrolment.
        case notEnrolled
        case notConnected
        /// The venue refuses forwarded orders for this account until `fw` is set, which
        /// the opening sequence does. Worth its own case because the sentence a user
        /// needs is "finish opening your desk", not "the order failed".
        case forwardingNotAllowed
        case noAccount
    }

    /// What the caller has to decide. Everything else is derived.
    public struct Draft: Sendable, Hashable {
        public let side: Side
        public let size: Size
        public let leverageHundredths: Int
        public let slippageBps: Int

        public init(side: Side, size: Size, leverageHundredths: Int, slippageBps: Int) {
            self.side = side
            self.size = size
            self.leverageHundredths = leverageHundredths
            self.slippageBps = slippageBps
        }
    }

    private let socket: PerplSocket
    private let market: Market
    private var counter: RequestCounter?
    private let tracker = OrderTracker()
    private var account: UInt32?
    private var allowsForwarding = true
    /// Frame ids are this device's own correlation handle and only have to be non-zero
    /// and unique within a connection.
    private var nextFrameID: Int64 = 1

    public init(socket: PerplSocket, market: Market) {
        self.socket = socket
        self.market = market
    }

    public var accountID: UInt32? { account }

    /// Opens the socket and takes the seeds the protocol requires from the snapshot.
    ///
    /// The snapshot arriving at all is the only evidence the gateway accepted the key —
    /// there is no acknowledgement frame — which is why this returns rather than reports.
    @discardableResult
    public func open(credentials: PerplCredentials, lastForwarded: Int64) async throws -> WalletSnapshot {
        let snapshot = try await socket.connect(credentials: credentials)
        guard let first = snapshot.firstAccount else { throw Failure.noAccount }
        account = first
        // Reseeded per connection, never carried across one. The venue's counter is the
        // authority and ours is a cache of it.
        if let counter {
            await counter.reseed(lastForwarded: lastForwarded)
        } else {
            counter = RequestCounter(lastForwarded: lastForwarded)
        }
        return snapshot
    }

    /// Whether the account will accept forwarded orders. Set from `mt: 21`; false means
    /// the desk is not finished opening rather than that anything failed.
    public func noteForwarding(_ allowed: Bool) { allowsForwarding = allowed }

    /// Sends one market order and returns the frame id to watch it by.
    ///
    /// The head block comes from the caller rather than being read here, because the
    /// deadline has to be computed against the block the venue most recently reported and
    /// this type does not own the market-state stream.
    public func place(_ draft: Draft, headBlock: Int64, ttlBlocks: UInt32 = 30) async throws -> Int64 {
        guard let account else { throw Failure.notConnected }
        guard let counter else { throw Failure.notConnected }
        guard allowsForwarding else { throw Failure.forwardingNotAllowed }
        guard await socket.isConnected else { throw Failure.notConnected }

        let frameID = nextFrameID
        nextFrameID += 1

        let request = try OrderBuilder.market(
            side: draft.side,
            market: market,
            account: account,
            size: draft.size,
            leverageHundredths: draft.leverageHundredths,
            slippageBps: draft.slippageBps,
            headBlock: headBlock,
            requestID: await counter.take(),
            frameID: frameID)

        // Before the send, not after. The gateway can answer faster than `send` returns,
        // and a status frame for an untracked id is dropped — which the user experiences
        // as an order that disappeared.
        try await tracker.track(frameID: frameID, deadlineBlock: request.lastBlock)
        do {
            try await socket.send(request)
        } catch {
            await tracker.forget(frameID)
            throw error
        }
        return frameID
    }

    /// One reader over the socket, applying every frame to the tracker and reporting
    /// which order moved.
    ///
    /// The venue refuses a second frame stream and splitting the first is worse than
    /// sharing it, so the single read lives in here rather than in a caller. Callers get
    /// phase changes; anything else on the socket is applied and not re-broadcast.
    ///
    /// Ends when the socket ends. A closed socket is not an error to swallow — the caller
    /// has to know the session is gone, which is why the stream finishes rather than
    /// quietly stopping.
    public func observe() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    for try await frame in try await socket.frames() {
                        // `mt: 21` carries the forwarding flag, which decides whether an
                        // order can be sent at all. Read here because this is the only
                        // reader.
                        if frame.kind == .account,
                           let account = try? frame.decode(PerplAccount.self) {
                            noteForwarding(account.allowsForwarding)
                            continuation.yield(.account(account))
                        }
                        if frame.kind == .positionsSnapshot || frame.kind == .positionsUpdate,
                           let positions = try? frame.decode(PositionsFrame.self) {
                            continuation.yield(.positions(positions.positions))
                        }
                        guard let moved = await apply(frame),
                              let phase = await phase(of: moved) else { continue }
                        continuation.yield(.order(frameID: moved, phase: phase))
                    }
                } catch {
                    // Falls through to finish: the socket closing is the event, and the
                    // close code has already been mapped by the socket itself.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func phase(of frameID: Int64) async -> OrderPhase? {
        await tracker.phase(of: frameID)
    }

    /// Feeds one inbound frame to the tracker and reports which order it moved, if any.
    ///
    /// Kept as a push rather than a subscription so the caller owns the single read of
    /// `socket.frames()` — the venue refuses a second frame stream, and splitting the
    /// first is worse than sharing it.
    public func apply(_ frame: InboundFrame) async -> Int64? {
        await tracker.apply(frame)
    }

    /// Anything still unsettled once the head block has passed its deadline is expired
    /// rather than pending forever. The difference between a sentence and a spinner that
    /// never ends.
    public func expire(headBlock: Int64) async -> [Int64] {
        await tracker.expire(headBlock: headBlock)
    }

    public func close() async {
        await socket.disconnect()
        account = nil
    }
}
