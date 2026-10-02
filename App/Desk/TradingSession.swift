import DeskAuth
import DeskFlow
import DeskMoney
import DeskPerpl
import Foundation
import Observation

@MainActor
@Observable
final class TradingSession {
    private(set) var order = OrderProgress()
    private(set) var account = LastGood<PerplAccount>()
    private(set) var positions = LastGood<[PerplPosition]>()

    var statusText: String? {
        if retryingUntil != nil { return "Perpl is retrying this order…" }
        return switch order.outcome {
        case nil: nil
        case .sending: "Sending to Perpl…"
        case .forwarded: "Forwarded — waiting for the book"
        case .settled: filledSentence
        case .failed(let reason, let failure): Self.failure(reason: reason, failure: failure)
        case .unfilled:
            (order.fill?.isClose == true ? "Not closed." : "Not filled.")
                + " The price moved past your slippage limit before the order could match. Nothing changed."
        case .expired:
            "Perpl hasn't confirmed this order yet. Check your positions before sending another."
        case .abandoned:
            "The connection to Perpl dropped before the order settled. "
                + "Check your position before sending another."
        case .rejected(let code, let subReason, let error):
            localProblem ?? error ?? Self.reason(code: code, subReason: subReason)
        }
    }

    var isBusy: Bool { order.outcome?.isBusy == true || retryingUntil != nil }
    var hasFailed: Bool {
        guard retryingUntil == nil else { return false }
        return switch order.outcome {
        case .rejected, .failed, .unfilled, .expired, .abandoned: true
        default: false
        }
    }

    /// The block until which Perpl may still retry the current order after its first
    /// failure. The ticket stays busy until then, so a second order can't double the first.
    private(set) var retryingUntil: Int64?
    private var retryBackstop: Task<Void, Never>?
    private var retryStartedAt = ContinuousClock.now
    static let blockTime = Duration.milliseconds(400)
    private var retryUnheard = false

    enum OrderOrigin: Equatable {
        case ticket(market: UInt32, side: Side)
        case copySheet(market: UInt32)
        case close(market: UInt32)
    }
    private(set) var orderOrigin: OrderOrigin?

    @ObservationIgnored private(set) var connectionEpoch = 0

    @ObservationIgnored private var unresolvedHand: [UInt32: [Int64: ContinuousClock.Instant]] = [:]

    func handOrderUnresolved(on marketID: UInt32) async -> Bool {
        guard var pending = unresolvedHand[marketID], !pending.isEmpty else { return false }
        for (id, sentAt) in pending {
            let age = ContinuousClock.now - sentAt
            let decided = switch await desk?.phase(of: id) {
            case .settled?, .unfilled?, .rejected?: true
            case .failed?: age > .seconds(30)
            default: age > .seconds(600)
            }
            if decided { pending[id] = nil }
        }
        unresolvedHand[marketID] = pending
        return !pending.isEmpty
    }

    private(set) var protectionProblem: String?

    func clearProtectionProblem() { protectionProblem = nil }

    @ObservationIgnored private(set) var handOrders: [UInt32: Int] = [:]

    private(set) var market: Market?
    private var orderMarket: Market?

    var lastFillSentence: String?

    private var filledSentence: String {
        guard let fill = order.fill, fill.filledRaw > 0, let market = orderMarket ?? market,
              let filled = market.size(fill.filledRaw) else { return "Filled" }
        let decimals = market.config.priceDecimals
        let price = market.price(fill.priceRaw).map { " at \($0.display(fractionDigits: decimals))" } ?? ""
        let fee = Money(raw: fill.feeRaw).map { " · fee \($0.display()) AUSD" } ?? ""
        let amount = filled.display(fractionDigits: filled.decimals)
        let verb = fill.isClose ? "Closed" : "Filled"
        guard fill.isPartial, let asked = market.size(fill.originalRaw) else {
            return "\(verb) \(amount) \(market.symbol)\(price)\(fee)"
        }
        return "Partly \(verb.lowercased()): \(amount) of \(asked.display(fractionDigits: asked.decimals)) \(market.symbol)\(price)\(fee). "
            + "The rest was cancelled at your slippage limit."
    }

    private var localProblem: String?

    private(set) var headBlock: Int64 = 0

    private var desk: OrderDesk?
    private var credentials: PerplCredentials?
    private var watching: Task<Void, Never>?
    /// One handshake at a time: an `await` makes this object re-entrant, so two callers
    /// could otherwise open two sockets.
    private var connecting: Task<Void, any Error>?
    private var frameID: Int64?
    private(set) var isConnected = false
    var onAccount: ((PerplAccount) -> Void)?
    var onPositions: (([PerplPosition]) -> Void)?
    var onNeedsUnlock: (@MainActor () async -> Bool)?
    private var connectionID = UUID()
    /// Updates that arrived before `desk.place` returned their frame id; the gateway can
    /// answer first, and dropping them would leave the ticket waiting on a filled order.
    private var unassociated: [(id: Int64, phase: OrderPhase)] = []

    var network: DeskNetwork = .testnet

    func adopt(apiKey: APIKey, session: SigningSession, market: Market) async {
        if desk != nil {
            await close()
            await retireDesk()
            orphanOrder()
        }
        credentials = PerplCredentials(apiKey: apiKey, session: session)
        desk = OrderDesk(socket: network.tradingSocket(), market: market, firstFrameID: frameSeed)
        self.market = market
    }

    /// Where the next desk's frame ids start: past every id an earlier desk used, so an
    /// answer still owed to an order of the old desk can't be read as a new order's.
    private var frameSeed: Int64 = 1

    private func retireDesk() async {
        guard let desk else { return }
        frameSeed = max(frameSeed, await desk.upcomingFrameID)
        await desk.close()
    }

    private func orphanOrder() {
        if retryingUntil != nil { retryUnheard = true }
        endRetrying()
        order.connectionLost()
    }

    func abandon() async {
        await close()
        await retireDesk()
        orphanOrder()
        positions = LastGood()
        account = LastGood()
        order.reset()
        orderMarket = nil
        orderOrigin = nil
        handOrders = [:]
        unresolvedHand = [:]
        protectionProblem = nil
        credentials = nil
        desk = nil
        headBlock = 0
    }

    func selectMarket(_ market: Market) async {
        guard credentials != nil else { return }
        if let desk, await desk.retarget(market) {
            self.market = market
            startClean()
            if !isConnected { try? await connect() }
            return
        }
        watching?.cancel()
        await retireDesk()
        orphanOrder()
        desk = OrderDesk(socket: network.tradingSocket(), market: market, firstFrameID: frameSeed)
        self.market = market
        startClean()
        isConnected = false
        try? await connect()
    }

    private func startClean() {
        guard order.outcome?.isTerminal == true, retryingUntil == nil else { return }
        order.reset()
        localProblem = nil
    }

    func noteHeadBlock(_ block: Int64) {
        // Monotonic: the two streams can report out of order, and an older block would
        // shorten an order's deadline.
        headBlock = max(headBlock, block)
        let current = headBlock
        if let until = retryingUntil, current > until,
           ContinuousClock.now - retryStartedAt >= Self.blockTime * Int(orderMarket?.orderWaitBlocks ?? 22) {
            endRetrying()
        }
        Task { [weak self] in
            guard let self, let desk = self.desk else { return }
            for id in await desk.expire(headBlock: current) {
                guard let phase = await desk.phase(of: id) else { continue }
                self.record(id, phase, await desk.fill(of: id))
            }
        }
    }

    func connect() async throws {
        if let connecting {
            try await connecting.value
            return
        }
        guard let desk, let credentials else { throw OrderDesk.Failure.notEnrolled }
        let id = UUID()
        connectionID = id
        let attempt = Task { [weak self] in
            try await desk.open(credentials: credentials)
            guard let self, self.connectionID == id else {
                throw PerplSocket.Failure.notConnected
            }
            // mt:19 is the authoritative initial balance. mt:21 is only a subsequent
            // update and may never arrive until the account changes.
            if let initial = await desk.accountSnapshot {
                self.record(.account(initial))
            }
            self.isConnected = true
            self.watching?.cancel()
            self.watching = Task { [weak self] in
                for await update in await desk.observe() {
                    guard let self else { return }
                    await record(update)
                }
                await self?.socketEnded(id: id)
            }
        }
        connecting = attempt
        // Only if it is still ours, or a later `connect()` could start a second `desk.open`.
        defer { if connectionID == id { connecting = nil } }
        do {
            try await attempt.value
        } catch {
            if connectionID == id { keepTrying() }
            throw error
        }
    }

    var isConnecting: Bool { connecting != nil }

    /// Closed positions as Perpl recorded them, newest first, at most five pages. Signed with the
    /// key already in memory; an empty answer means none could be read, not that none exist.
    func closedHistory() async -> [PerplPosition] {
        guard let credentials, let configuration = try? network.perpl() else { return [] }
        let rest = PerplREST(configuration: configuration)
        await rest.adopt(credentials)
        var rows: [PerplPosition] = []
        var cursor: String?
        for _ in 0..<5 {
            var query = [(name: "count", value: "100")]
            if let cursor { query.append((name: "page", value: cursor)) }
            guard let endpoint = try? PerplEndpoint(method: .get, path: "/v1/trading/position-history", query: query),
                  let page = try? await rest.signedJSON(endpoint, as: PositionHistoryPage.self) else { break }
            rows += page.positions
            guard let next = page.nextPage, next != cursor else { break }
            cursor = next
        }
        return PositionBook.closedRows(in: rows)
    }

    private func keepTrying() {
        guard reconnecting == nil else { return }
        reconnecting = Task { [weak self] in
            var delay = Duration.seconds(2)
            while !Task.isCancelled {
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled, self.credentials != nil, !self.isConnected else { break }
                do { try await self.connect(); break } catch { delay = min(delay * 2, .seconds(60)) }
            }
            self?.reconnecting = nil
        }
    }
    private var reconnecting: Task<Void, Never>?

    func reconnect() async {
        guard credentials != nil else { return }
        connecting?.cancel()
        connecting = nil
        watching?.cancel()
        await desk?.close()
        isConnected = false
        try? await connect()
    }

    func close() async {
        reconnecting?.cancel()
        reconnecting = nil
        if retryingUntil != nil { retryUnheard = true }
        connectionEpoch += 1
        connectionID = UUID()
        connecting?.cancel()
        connecting = nil
        watching?.cancel()
        watching = nil
        await desk?.close()
        isConnected = false
    }

    /// `market` is the one the draft was priced on, never the desk's default: the desk
    /// may point elsewhere by the time the send goes out.
    func place(_ draft: OrderDesk.Draft, in market: Market, origin: OrderOrigin) async {
        localProblem = nil
        endRetrying()
        order.begin()
        orderMarket = market
        orderOrigin = origin
        handOrders[market.id, default: 0] += 1
        do {
            guard let desk else { throw OrderDesk.Failure.notEnrolled }
            if !isConnected {
                do {
                    try await connect()
                } catch {
                    guard let unlock = onNeedsUnlock, await unlock() else { throw error }
                    if !isConnected { try await connect() }
                }
            }
            let id = try await desk.place(draft, headBlock: headBlock, in: market)
            unresolvedHand[market.id, default: [:]][id] = .now
            let before = order.outcome
            order.associate(id)
            if let current = await desk.phase(of: id) { order.apply(id: id, phase: current, fill: await desk.fill(of: id)) }
            noteOutcome(since: before)
            awaitAnswer(id)
        } catch {
            Haptics.failure()
            localProblem = Self.sentence(for: error)
            order.failLocally()
        }
    }

    func closePosition(_ position: PerplPosition, size: Size? = nil, slippageBps: Int, in market: Market) async {
        localProblem = nil
        endRetrying()
        order.begin()
        orderMarket = market
        orderOrigin = .close(market: position.marketID)
        handOrders[position.marketID, default: 0] += 1
        do {
            guard let desk else { throw OrderDesk.Failure.notEnrolled }
            if !isConnected {
                do {
                    try await connect()
                } catch {
                    guard let unlock = onNeedsUnlock, await unlock() else { throw error }
                    if !isConnected { try await connect() }
                }
            }
            let id = try await desk.closePosition(
                position, size: size, slippageBps: slippageBps, headBlock: headBlock, in: market)
            unresolvedHand[market.id, default: [:]][id] = .now
            let before = order.outcome
            order.associate(id)
            if let current = await desk.phase(of: id) { order.apply(id: id, phase: current, fill: await desk.fill(of: id)) }
            noteOutcome(since: before)
            awaitAnswer(id)
        } catch {
            Haptics.failure()
            localProblem = Self.sentence(for: error)
            order.failLocally()
        }
    }

    /// Never asks for Face ID: an automatic order that finds Desk locked is skipped,
    /// not prompted for.
    func placeCopy(_ draft: OrderDesk.Draft, in market: Market) async throws -> Int64 {
        guard let desk else { throw OrderDesk.Failure.notEnrolled }
        if !isConnected { try await connect() }
        return try await desk.place(draft, headBlock: headBlock, in: market)
    }

    func closeCopy(_ position: PerplPosition, size: Size, in market: Market) async throws -> Int64 {
        guard let desk else { throw OrderDesk.Failure.notEnrolled }
        if !isConnected { try await connect() }
        return try await desk.closePosition(
            position, size: size, slippageBps: min(50, market.maxMarketSlippageBps),
            headBlock: headBlock, in: market)
    }

    func phase(of frameID: Int64) async -> OrderPhase? {
        await desk?.phase(of: frameID)
    }

    func fill(of frameID: Int64) async -> OrderFill? {
        await desk?.fill(of: frameID)
    }

    func isPastDeadline(_ frameID: Int64) async -> Bool {
        guard let deadline = await desk?.deadline(of: frameID) else { return true }
        return headBlock > deadline
    }

    func protectPosition(
        _ position: PerplPosition, stopLoss: Price?, takeProfit: Price?, slippageBps: Int, in market: Market
    ) async -> Bool {
        protectionProblem = nil
        do {
            guard let desk else { throw OrderDesk.Failure.notEnrolled }
            if !isConnected {
                do {
                    try await connect()
                } catch {
                    guard let unlock = onNeedsUnlock, await unlock() else { throw error }
                    if !isConnected { try await connect() }
                }
            }
            try await desk.protectPosition(
                position, stopLoss: stopLoss, takeProfit: takeProfit,
                slippageBps: slippageBps, in: market)
            Haptics.success()
            return true
        } catch {
            Haptics.failure()
            protectionProblem = Self.sentence(for: error)
            return false
        }
    }

    func clear() {
        guard !isBusy else { return }
        order.reset()
        localProblem = nil
        endRetrying()
    }

    private func record(_ id: Int64, _ phase: OrderPhase, _ fill: OrderFill?) {
        let before = order.outcome
        order.apply(id: id, phase: phase, fill: fill)
        noteOutcome(since: before)
    }

    private func noteOutcome(since before: OrderProgress.Outcome?) {
        guard order.outcome != before else { return }
        switch order.outcome {
        case .settled:
            endRetrying()
            lastFillSentence = filledSentence
            order.fill?.isPartial == true ? Haptics.selection() : Haptics.success()
        case .failed:
            beginRetrying()
        case .rejected, .unfilled, .expired:
            endRetrying()
            Haptics.failure()
        default: break
        }
    }

    private func beginRetrying() {
        guard retryingUntil == nil else { return }
        retryStartedAt = .now
        retryingUntil = headBlock + Int64(orderMarket?.orderWaitBlocks ?? market?.orderWaitBlocks ?? 22)
        retryBackstop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.endRetrying()
        }
    }

    private func awaitAnswer(_ id: Int64) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, self.order.outcome?.isBusy == true else { return }
            self.record(id, .expired, nil)
        }
    }

    private func endRetrying() {
        retryBackstop?.cancel()
        retryBackstop = nil
        let unheard = retryUnheard
        retryUnheard = false
        guard retryingUntil != nil else { return }
        retryingUntil = nil
        guard case .failed = order.outcome else { return }
        if unheard { order.failureUnheard() }
        Haptics.failure()
    }

    private func record(_ event: OrderDesk.Event) {
        switch event {
        case .account(let value):
            account.record(value)
            onAccount?(value)
        case .positions(let value, let isSnapshot):
            let portfolio = isSnapshot
                ? value
                : PositionBook.merging(existing: positions.value ?? [], updates: value)
            positions.record(portfolio)
            onPositions?(portfolio)
        case .order(let id, let phase, let fill):
            record(id, phase, fill)
        }
    }

    static func merging(
        existing: [PerplPosition], updates: [PerplPosition]
    ) -> [PerplPosition] {
        PositionBook.merging(existing: existing, updates: updates)
    }

    private func socketEnded(id: UUID) {
        guard id == connectionID else { return }
        isConnected = false
        connectionEpoch += 1
        keepTrying()
        if retryingUntil != nil { retryUnheard = true }
        account.recordFailure("The Perpl account stream disconnected.")
        positions.recordFailure("The Perpl position stream disconnected.")
        order.connectionLost()
    }

    /// A venue refusal (`mt: 24`, `st: 7`): `fr` says why and wins when present; `sr` says
    /// where, and covers the refusals that carry no `fr`.
    static func failure(reason: Int, failure: Int?) -> String {
        switch failure {
        case 1: return "Not enough free collateral for this order and its fee. Nothing was filled."
        case 2: return "Not enough free collateral to add to this position. Nothing was filled."
        case 3: return "Not enough free collateral to flip this position. Nothing was filled."
        case 4: return "There was no position left to close. It may already be closed."
        case 5: return "Perpl refused this fill to keep the market solvent. Nothing was filled; try a smaller size."
        case 6: return "Closing at this price would realise a negative position value. Nothing was closed."
        case 7: return "Perpl had no fresh price to value the order. Nothing was filled; try again in a moment."
        case 8: return "This position's unrealised loss is above what the order may cover. Nothing was filled."
        default: break
        }
        switch reason {
        case 1: return "Not enough free collateral for this order. Nothing was filled."
        case 2: return "This Perpl account is frozen. Nothing was filled."
        case 10: return "The close was larger than the position. Nothing was closed."
        case 14: return "The order reached Perpl too late to execute. Nothing was filled; try again."
        case 17, 39: return "The order is below Perpl's minimum size. Nothing was filled."
        case 34: return "Perpl will not accept orders on this account until order forwarding is switched on. Nothing was sent."
        case 40: return "The price was outside the range Perpl accepts. Nothing was filled."
        case 42: return "The size was outside the range Perpl accepts. Nothing was filled."
        case 12: return "Perpl's exchange is paused right now. Nothing was filled."
        default: return "Perpl refused the order (reason \(reason)). Nothing was filled."
        }
    }

    static func reason(code: Int, subReason: Int?) -> String {
        switch subReason {
        case 32:
            return "Perpl rejected the order's sequence number. This is a fault in Desk, "
                + "not in your account. Try once more."
        case .some(let sub):
            return "Perpl rejected the order (code \(code), reason \(sub)). Nothing was filled."
        case nil:
            return "Perpl rejected the order (code \(code)). Nothing was filled."
        }
    }

    static func sentence(for error: any Error) -> String {
        switch error {
        case OrderDesk.Failure.notEnrolled:
            return "Your desk is not enrolled with Perpl yet, so no order can be signed. "
                + "Finish opening your desk first."
        case OrderDesk.Failure.forwardingNotAllowed:
            return "Perpl will not accept orders on this account until order forwarding "
                + "is switched on, which is the last step of opening your desk."
        case OrderDesk.Failure.notConnected:
            return "Not connected to Perpl. Nothing was sent."
        case OrderDesk.Failure.noAccount:
            return "Perpl accepted your key but did not return a trading account. "
                + "Nothing was sent."
        case PerplSocket.Failure.signInRefused:
            return "Perpl rejected the saved trading credential. Sign in with Face ID "
                + "again to refresh it; nothing was sent."
        case PerplSocket.Failure.idleTimeout, PerplSocket.Failure.handshakeTimedOut:
            return "Perpl did not finish reconnecting in time. Check your connection and try again."
        case PerplSocket.Failure.malformedWalletSnapshot:
            return "Perpl answered, but its account snapshot has a format this version of Desk cannot read. Nothing was sent."
        case PerplSocket.Failure.closed(let code, _):
            return "Perpl closed the trading connection (code \(code)). Nothing was sent; try again."
        case PerplSocket.Failure.notConnected, PerplSocket.Failure.notAuthenticated:
            return "The Perpl connection ended before the order was sent. Try once more to reconnect."
        case PerplSocket.Failure.alreadyConnected:
            return "Desk found a stale Perpl connection. Try once more; it has now been reset."
        case PerplSocket.Failure.framesAlreadyStarted:
            return "Desk could not restart the Perpl order stream. Nothing was sent."
        case OrderBuilder.Failure.sizeMustBePositive:
            return "Enter an order amount greater than zero."
        case OrderBuilder.Failure.leverageOutOfRange(_, let maximum):
            return "That leverage is above this market's \(maximum / 100)× limit."
        case OrderBuilder.Failure.slippageOutOfRange(_, let maximum):
            return "That slippage is above Perpl's \(maximum) bps limit for this market."
        case OrderBuilder.Failure.sizeScaleMismatch:
            return "The order size does not match this market's precision. Nothing was sent."
        case OrderBuilder.Failure.priceScaleMismatch:
            return "The live price precision does not match this market. Nothing was sent."
        case OrderBuilder.Failure.deadlineOverflow:
            return "The latest Monad block could not be used for this order. Nothing was sent."
        case OrderBuilder.Failure.frameIDMustBeNonZero, OrderBuilder.Failure.priceMustBePositive:
            return "Desk could not build a valid Perpl order. Nothing was sent."
        case SigningSession.Failure.closed:
            return "Desk is locked, so nothing was sent. Unlock with Face ID and send it again."
        case let url as URLError:
            return url.code == .notConnectedToInternet
                ? "Your phone is offline. Nothing was sent."
                : "The network interrupted the Perpl connection. Nothing was sent; try again."
        default:
            return "The order could not be sent. Nothing left your phone (\(String(describing: error)))."
        }
    }
}
