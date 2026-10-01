import DeskAuth
import DeskFlow
import DeskMoney
import DeskPerpl
import Foundation
import Observation

@MainActor
@Observable
final class TradingSession {
    /// The order's state machine lives in `DeskFlow` and is tested there. This type
    /// turns its outcomes into sentences and nothing else — the association window, the
    /// replay and the terminal rule are not re-implemented here, because they were once
    /// and that is how the race got in.
    private(set) var order = OrderProgress()
    private(set) var account = LastGood<PerplAccount>()
    private(set) var positions = LastGood<[PerplPosition]>()

    /// The sentence the ticket shows, or nothing while there is no order.
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
    /// The socket went away during the retry wait, so Perpl's retry could have filled
    /// unheard.
    private var retryUnheard = false

    /// The market of the order in flight or last sent by hand.
    var orderMarketID: UInt32? { orderMarket?.id }

    /// Orders the person sent by hand, per market. Copy trading reads it to tell a
    /// position the person opened from one its own unanswered order opened.
    @ObservationIgnored private(set) var handOrders: [UInt32: Int] = [:]

    /// The market the desk is signing for.
    private(set) var market: Market?
    /// The market the current order was sent on, so its fill is read at its own scales
    /// even after the person has moved to another market.
    private var orderMarket: Market?

    /// The last fill in words, kept past `clear()` so the toast after a ticket closes can
    /// say what filled rather than only that something did.
    var lastFillSentence: String?

    /// "Filled 0.012 BTC at 83,120.5 · fee 0.35 AUSD", or the partial version of it. Falls
    /// back to one word when the venue's update carried no sizes.
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

    /// A failure raised before the order ever reached the desk — no enrolled key, no
    /// connection — which has no venue code behind it and needs its own sentence.
    private var localProblem: String?

    /// The block the venue most recently reported. An order's deadline is computed
    /// against it, so a stale one produces an order that expires on arrival.
    private(set) var headBlock: Int64 = 0

    private var desk: OrderDesk?
    private var credentials: PerplCredentials?
    private var watching: Task<Void, Never>?
    /// One handshake at a time. Main-actor isolation prevents data races, but an `await`
    /// makes this object re-entrant: market selection and an order tap could previously
    /// open two sockets, with either path closing the other while it authenticated.
    private var connecting: Task<Void, any Error>?
    private var frameID: Int64?
    private(set) var isConnected = false
    var onAccount: ((PerplAccount) -> Void)?
    var onPositions: (([PerplPosition]) -> Void)?
    /// Asked when connecting fails. Answers true once Desk has been unlocked, in which
    /// case the connection is tried once more; false leaves the original failure standing.
    var onNeedsUnlock: (@MainActor () async -> Bool)?
    private var connectionID = UUID()
    /// Updates that arrived before the order they belong to had a frame id here.
    ///
    /// The window is real: `desk.place` tracks the order and sends it, and the gateway can
    /// answer while that call is still unwinding — so `observe` can yield a forwarded or
    /// even settled update before `place` has returned the id to compare against. Without
    /// somewhere to put those, the answer is dropped and the ticket waits forever on an
    /// order that already filled.
    private var unassociated: [(id: Int64, phase: OrderPhase)] = []

    /// Called once a desk has been opened and enrolled. Until then there is nothing to
    /// connect with, which is a state rather than a fault.
    /// Set before a desk is adopted; every socket this session opens belongs to it.
    var network: DeskNetwork = .testnet

    func adopt(apiKey: APIKey, session: SigningSession, market: Market) {
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

    /// Forgets the enrolled key along with the socket, for a switch to another network
    /// whose exchange has never seen that key.
    func abandon() async {
        await close()
        await retireDesk()
        credentials = nil
        desk = nil
        // Block numbers belong to a chain; another network's are tens of millions apart.
        headBlock = 0
        endRetrying()
    }

    /// Points the order desk at the instrument the person selected. Within one exchange
    /// instance the desk keeps its socket and every order it follows, so a copy or a
    /// retry in flight still hears its answer; another instance needs a new desk.
    func selectMarket(_ market: Market) async {
        guard credentials != nil else { return }
        if let desk, await desk.retarget(market) {
            self.market = market
            startClean()
            if !isConnected { try? await connect() }
            return
        }
        watching?.cancel()
        if retryingUntil != nil { retryUnheard = true }
        await retireDesk()
        desk = OrderDesk(socket: network.tradingSocket(), market: market, firstFrameID: frameSeed)
        self.market = market
        startClean()
        isConnected = false
        try? await connect()
    }

    /// A finished order belongs to the market it was sent on; the next screen starts
    /// clean. One Perpl may still retry is not finished.
    private func startClean() {
        guard order.outcome?.isTerminal == true, retryingUntil == nil else { return }
        order.reset()
        localProblem = nil
    }

    func noteHeadBlock(_ block: Int64) {
        // Monotonic. The context and the heartbeat stream can report out of order, and
        // an order deadline computed from an older block than one already seen would be
        // shorter than intended.
        headBlock = max(headBlock, block)
        let current = headBlock
        if let until = retryingUntil, current > until { endRetrying() }
        Task { [weak self] in
            guard let self, let desk = self.desk else { return }
            for id in await desk.expire(headBlock: current) {
                guard let phase = await desk.phase(of: id) else { continue }
                self.record(id, phase, await desk.fill(of: id))
            }
        }
    }

    /// Connects, and begins the single read of the socket.
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
                // The stream finishing means the socket went away. An order still in
                // flight has no answer coming, and saying so beats a spinner forever.
                await self?.socketEnded(id: id)
            }
        }
        connecting = attempt
        // Only if it is still ours: a cancelled attempt that cleared this slot unconditionally
        // let a later `connect()` start a second `desk.open`, and the loser of that race left
        // an authenticated socket with nobody reading its frames.
        defer { if connectionID == id { connecting = nil } }
        try await attempt.value
    }

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
        if retryingUntil != nil { retryUnheard = true }
        connectionID = UUID()
        connecting?.cancel()
        connecting = nil
        watching?.cancel()
        watching = nil
        await desk?.close()
        isConnected = false
    }

    /// Sends the order, or explains why it cannot be sent.
    ///
    /// The association window is closed in both directions: anything the watcher held
    /// while the id was unknown is replayed by `associate`, and the tracker — which is the
    /// authority and never walks a terminal phase backwards — is asked directly in case an
    /// update landed with no watcher tick left to carry it.
    func place(_ draft: OrderDesk.Draft) async {
        localProblem = nil
        endRetrying()
        order.begin()
        orderMarket = market
        if let id = market?.id { handOrders[id, default: 0] += 1 }
        do {
            guard let desk else { throw OrderDesk.Failure.notEnrolled }
            if !isConnected {
                // Mobile sockets are routinely suspended between opening the ticket and
                // confirming it. Reconnect at the point of intent instead of making the
                // user leave the sheet and sign in again.
                do {
                    try await connect()
                } catch {
                    // Signing in needs the trading key, and Desk may be locked — the key
                    // is wiped after a spell in the background or when the phone locks.
                    // One Face ID prompt, then the order carries on. This is a closing
                    // order as often as an opening one, and it must not be turned away
                    // for want of a key the person can restore with a glance.
                    guard let unlock = onNeedsUnlock, await unlock() else { throw error }
                    if !isConnected { try await connect() }
                }
            }
            let id = try await desk.place(draft, headBlock: headBlock)
            let before = order.outcome
            order.associate(id)
            if let current = await desk.phase(of: id) { order.apply(id: id, phase: current, fill: await desk.fill(of: id)) }
            noteOutcome(since: before)
        } catch {
            Haptics.failure()
            localProblem = Self.sentence(for: error)
            order.failLocally()
        }
    }

    func closePosition(_ position: PerplPosition, size: Size? = nil, slippageBps: Int) async {
        localProblem = nil
        endRetrying()
        order.begin()
        orderMarket = market
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
                position, size: size, slippageBps: slippageBps, headBlock: headBlock)
            let before = order.outcome
            order.associate(id)
            if let current = await desk.phase(of: id) { order.apply(id: id, phase: current, fill: await desk.fill(of: id)) }
            noteOutcome(since: before)
        } catch {
            Haptics.failure()
            localProblem = Self.sentence(for: error)
            order.failLocally()
        }
    }

    /// Sends a copied trade on any market without touching the ticket's own progress,
    /// and never asks for Face ID: an automatic order that finds Desk locked is skipped,
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

    /// Whether Desk's own wait for this order is over: the head block has passed the
    /// deadline it was tracked with. True for an order the desk no longer knows.
    func isPastDeadline(_ frameID: Int64) async -> Bool {
        guard let deadline = await desk?.deadline(of: frameID) else { return true }
        return headBlock > deadline
    }

    func protectPosition(
        _ position: PerplPosition, stopLoss: Price?, takeProfit: Price?, slippageBps: Int
    ) async -> Bool {
        localProblem = nil
        do {
            guard let desk else { throw OrderDesk.Failure.notEnrolled }
            if !isConnected { try await connect() }
            try await desk.protectPosition(
                position, stopLoss: stopLoss, takeProfit: takeProfit,
                slippageBps: slippageBps)
            Haptics.success()
            return true
        } catch {
            Haptics.failure()
            localProblem = Self.sentence(for: error)
            return false
        }
    }

    func clear() {
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

    /// Perpl retries an order for its retry window after a first failure, and a later
    /// success still decides it. The failure is said once that window has passed, or
    /// after twenty seconds if the head block stops arriving.
    private func beginRetrying() {
        guard retryingUntil == nil else { return }
        retryingUntil = headBlock + Int64(orderMarket?.orderWaitBlocks ?? market?.orderWaitBlocks ?? 22)
        retryBackstop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.endRetrying()
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

    /// Position updates are deltas, not miniature snapshots. The folding lives in
    /// `PositionBook`, inside the package, where it can be tested — it was here, in the
    /// app target, which has no tests at all.
    static func merging(
        existing: [PerplPosition], updates: [PerplPosition]
    ) -> [PerplPosition] {
        PositionBook.merging(existing: existing, updates: updates)
    }

    private func socketEnded(id: UUID) {
        guard id == connectionID else { return }
        isConnected = false
        if retryingUntil != nil { retryUnheard = true }
        account.recordFailure("The Perpl account stream disconnected.")
        positions.recordFailure("The Perpl position stream disconnected.")
        order.connectionLost()
    }

    /// The venue's sub-reason codes, as sentences.
    ///
    /// `32` is the one worth naming: it means the request id was at or below the last
    /// forwarded one, which is this app's bug rather than the user's, and a generic
    /// "rejected" would send them hunting for a problem with their account.
    /// A venue refusal (`mt: 24`, `st: 7`) in words. `fr` says why and is the better
    /// sentence when present; `sr` says where, and covers the refusals that carry no `fr`.
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
