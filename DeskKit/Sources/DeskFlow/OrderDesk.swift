import DeskMoney
import DeskPerpl
import Foundation

/// An actor so socket, `rq` counter and tracker move together: racing request ids get `sr: 32`.
/// `mt: 3` with `code: 0` means forwarded, not filled; only `mt: 24` settles an order.
public actor OrderDesk {
    public enum Event: Sendable, Hashable {
        case account(PerplAccount)
        /// mt:26 replaces the portfolio; mt:27 only patches the positions it carries.
        case positions([PerplPosition], isSnapshot: Bool)
        case order(frameID: Int64, phase: OrderPhase, fill: OrderFill?)
    }
    public enum Failure: Error, Sendable, Equatable {
        case notEnrolled
        case notConnected
        /// The venue refuses forwarded orders until the opening sequence sets `fw`.
        case forwardingNotAllowed
        case noAccount
    }

    public struct Draft: Sendable, Hashable {
        public struct Protection: Sendable, Hashable {
            public let stopLoss: Price?
            public let takeProfit: Price?

            public init(stopLoss: Price? = nil, takeProfit: Price? = nil) {
                self.stopLoss = stopLoss
                self.takeProfit = takeProfit
            }
        }

        public let side: Side
        public let size: Size
        public let leverageHundredths: Int
        public let slippageBps: Int
        public let protection: Protection?

        public init(
            side: Side, size: Size, leverageHundredths: Int, slippageBps: Int,
            protection: Protection? = nil
        ) {
            self.side = side
            self.size = size
            self.leverageHundredths = leverageHundredths
            self.slippageBps = slippageBps
            self.protection = protection
        }
    }

    private let socket: PerplSocket
    private var market: Market
    private var counter: RequestCounter?
    private let tracker = OrderTracker()
    private var account: UInt32?
    private var allowsForwarding = true
    private var initialAccount: PerplAccount?
    private var nextFrameID: Int64 = 1

    public init(socket: PerplSocket, market: Market, firstFrameID: Int64 = 1) {
        self.socket = socket
        self.market = market
        nextFrameID = max(1, firstFrameID)
    }

    public var upcomingFrameID: Int64 { nextFrameID }

    public func retarget(_ next: Market) -> Bool {
        guard next.instanceID == market.instanceID else { return false }
        market = next
        return true
    }

    public var accountID: UInt32? { account }

    @discardableResult
    public func open(credentials: PerplCredentials) async throws -> WalletSnapshot {
        let snapshot = try await socket.connect(credentials: credentials)
        guard let selected = snapshot.account(for: market.instanceID) else { throw Failure.noAccount }
        account = selected.id
        initialAccount = selected.accountUpdate
        if let initialAccount { allowsForwarding = initialAccount.allowsForwarding }
        let lastForwarded = selected.lastForwarded ?? 0
        // Reseeded per connection, never carried across one. The venue's counter is the
        // authority and ours is a cache of it.
        if let counter {
            await counter.reseed(lastForwarded: lastForwarded)
        } else {
            counter = RequestCounter(lastForwarded: lastForwarded)
        }
        return snapshot
    }

    public var accountSnapshot: PerplAccount? { initialAccount }

    public func noteForwarding(_ allowed: Bool) { allowsForwarding = allowed }

    public func place(
        _ draft: Draft, headBlock: Int64, ttlBlocks: UInt32 = 30, in other: Market? = nil
    ) async throws -> Int64 {
        let market = try target(other)
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

        // Track before sending: the gateway can answer before `send` returns and drops untracked ids.
        // `lb` is zero on the wire; this local deadline stays out of the payload.
        let (deadline, overflow) = headBlock.addingReportingOverflow(Int64(market.orderWaitBlocks))
        try await tracker.track(
            frameID: frameID,
            requestID: request.requestID,
            deadlineBlock: overflow ? Int64.max : deadline)
        do {
            try await socket.send(request)
        } catch {
            await tracker.forget(frameID)
            throw error
        }
        // The opening order may fill from here on; never forget it if a protective send
        // fails, or a live position would look as though it never existed.
        try await sendProtection(for: draft, linkedTo: request.requestID, in: market)
        return frameID
    }

    private func target(_ other: Market?) throws -> Market {
        guard let other else { return market }
        guard other.instanceID == market.instanceID else { throw Failure.notConnected }
        return other
    }

    private func sendProtection(for draft: Draft, linkedTo openingRequestID: Int64, in market: Market) async throws {
        guard let protection = draft.protection, let account, let counter else { return }
        let triggers: [(Price?, TriggerPriceCondition)] = [
            (protection.stopLoss,
             draft.side == .long ? .lessThanOrEqualMark : .greaterThanOrEqualMark),
            (protection.takeProfit,
             draft.side == .long ? .greaterThanOrEqualMark : .lessThanOrEqualMark),
        ]
        for (price, condition) in triggers {
            guard let price else { continue }
            let frameID = nextFrameID
            nextFrameID += 1
            let trigger = try OrderBuilder.protectiveClose(
                side: draft.side, market: market, account: account, size: draft.size,
                triggerPrice: price, condition: condition,
                linkedRequestID: openingRequestID,
                slippageBps: draft.slippageBps,
                requestID: await counter.take(), frameID: frameID)
            // Trigger orders have no short local expiry. The linked position/request is
            // their lifetime; Perpl will cancel them when that relationship ends.
            try await tracker.track(
                frameID: frameID, requestID: trigger.requestID, deadlineBlock: .max)
            do {
                try await socket.send(trigger)
            } catch {
                await tracker.forget(frameID)
                throw error
            }
        }
    }

    /// Closes an existing position with Perpl's dedicated reduce-only close type. This
    /// must never be implemented as an opposite open: that can invert exposure instead.
    public func closePosition(
        _ position: PerplPosition,
        size requestedSize: Size? = nil,
        slippageBps: Int,
        headBlock: Int64,
        in other: Market? = nil
    ) async throws -> Int64 {
        let market = try target(other)
        guard let account else { throw Failure.notConnected }
        guard let counter else { throw Failure.notConnected }
        guard allowsForwarding else { throw Failure.forwardingNotAllowed }
        guard await socket.isConnected else { throw Failure.notConnected }
        guard position.marketID == market.id,
              let fullSize = market.size(position.sizeRaw) else { throw Failure.notConnected }
        let size = requestedSize ?? fullSize
        guard size.decimals == fullSize.decimals, size.raw > 0, size.raw <= fullSize.raw else {
            throw OrderBuilder.Failure.sizeMustBePositive
        }

        let frameID = nextFrameID
        nextFrameID += 1
        let request = try OrderBuilder.close(
            side: position.side, market: market, account: account, size: size,
            slippageBps: slippageBps, headBlock: headBlock,
            requestID: await counter.take(), frameID: frameID)
        let (deadline, overflow) = headBlock.addingReportingOverflow(Int64(market.orderWaitBlocks))
        try await tracker.track(
            frameID: frameID, requestID: request.requestID,
            deadlineBlock: overflow ? Int64.max : deadline)
        do {
            try await socket.send(request)
        } catch {
            await tracker.forget(frameID)
            throw error
        }
        return frameID
    }

    public func protectPosition(
        _ position: PerplPosition,
        stopLoss: Price?,
        takeProfit: Price?,
        slippageBps: Int,
        in other: Market? = nil
    ) async throws {
        let market = try target(other)
        guard let account else { throw Failure.notConnected }
        guard let counter else { throw Failure.notConnected }
        guard allowsForwarding else { throw Failure.forwardingNotAllowed }
        guard await socket.isConnected else { throw Failure.notConnected }
        guard position.marketID == market.id,
              let size = market.size(position.sizeRaw) else { throw Failure.notConnected }

        let triggers: [(Price?, TriggerPriceCondition)] = [
            (stopLoss, position.side == .long ? .lessThanOrEqualMark : .greaterThanOrEqualMark),
            (takeProfit, position.side == .long ? .greaterThanOrEqualMark : .lessThanOrEqualMark),
        ]
        for (price, condition) in triggers {
            guard let price else { continue }
            let frameID = nextFrameID
            nextFrameID += 1
            let request = try OrderBuilder.protectiveClose(
                side: position.side, market: market, account: account, size: size,
                triggerPrice: price, condition: condition,
                linkedPositionID: position.positionID, slippageBps: slippageBps,
                requestID: await counter.take(), frameID: frameID)
            try await tracker.track(
                frameID: frameID, requestID: request.requestID, deadlineBlock: .max)
            do { try await socket.send(request) }
            catch {
                await tracker.forget(frameID)
                throw error
            }
        }
    }

    /// The only reader over the socket: the venue refuses a second frame stream.
    public func observe() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    for try await frame in try await socket.frames() {
                        if frame.kind == .account,
                           let account = try? frame.decode(PerplAccount.self) {
                            noteForwarding(account.allowsForwarding)
                            continuation.yield(.account(account))
                        }
                        if frame.kind == .positionsSnapshot || frame.kind == .positionsUpdate,
                           let positions = try? frame.decode(PositionsFrame.self) {
                            continuation.yield(.positions(
                                positions.positions,
                                isSnapshot: frame.kind == .positionsSnapshot))
                        }
                        for moved in await applyAll(frame) {
                            guard let phase = await phase(of: moved) else { continue }
                            continuation.yield(.order(frameID: moved, phase: phase, fill: await fill(of: moved)))
                        }
                    }
                } catch {
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func phase(of frameID: Int64) async -> OrderPhase? {
        await tracker.phase(of: frameID)
    }

    public func fill(of frameID: Int64) async -> OrderFill? {
        await tracker.fill(of: frameID)
    }

    public func deadline(of frameID: Int64) async -> Int64? {
        await tracker.deadline(of: frameID)
    }

    public func applyAll(_ frame: InboundFrame) async -> [Int64] {
        await tracker.applyAll(frame)
    }

    public func apply(_ frame: InboundFrame) async -> Int64? {
        await tracker.apply(frame)
    }

    public func expire(headBlock: Int64) async -> [Int64] {
        await tracker.expire(headBlock: headBlock)
    }

    public func close() async {
        await socket.disconnect()
        account = nil
        initialAccount = nil
    }
}
