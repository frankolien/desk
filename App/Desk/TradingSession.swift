import DeskAuth
import DeskFlow
import DeskMoney
import DeskPerpl
import Foundation
import Observation

/// What stands between the ticket and the venue.
///
/// The ticket should not know about sockets, request counters or head blocks, and it
/// should not decide whether an order can be sent — it should ask, and be told in a
/// sentence. So this owns the `OrderDesk`, the enrolled key and the block the venue last
/// reported, and exposes exactly two things: place an order, and watch what happens to it.
///
/// It is also the honest boundary. Before enrolment there is no key to sign with, and
/// `place` says so by throwing `notEnrolled` from the same call the real path takes —
/// rather than the ticket short-circuiting and never reaching the desk at all. When a key
/// appears, nothing in the ticket changes.
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
        switch order.outcome {
        case nil: nil
        case .sending: "Sending to Perpl…"
        case .forwarded: "Forwarded — waiting for the book"
        case .settled: "Filled"
        case .expired: "The order expired before it reached the book. Nothing was filled."
        case .abandoned:
            "The connection to Perpl dropped before the order settled. "
                + "Check your position before sending another."
        case .rejected(let code, let subReason, let error):
            localProblem ?? error ?? Self.reason(code: code, subReason: subReason)
        }
    }

    var isBusy: Bool { order.outcome?.isBusy == true }
    var hasFailed: Bool {
        switch order.outcome {
        case .rejected, .expired, .abandoned: true
        default: false
        }
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
        desk = OrderDesk(socket: network.tradingSocket(), market: market)
    }

    /// Forgets the enrolled key along with the socket, for a switch to another network
    /// whose exchange has never seen that key.
    func abandon() async {
        await close()
        credentials = nil
        desk = nil
    }

    /// Rebuilds the order desk for the instrument the person selected. Market discovery
    /// and order construction now share the same Perpl market instead of every row
    /// eventually submitting BTC.
    func selectMarket(_ market: Market) async {
        guard credentials != nil else { return }
        watching?.cancel()
        await desk?.close()
        desk = OrderDesk(socket: network.tradingSocket(), market: market)
        isConnected = false
        try? await connect()
    }

    func noteHeadBlock(_ block: Int64) {
        // Monotonic. The context and the market-state stream can report out of order, and
        // an order deadline computed from an older block than one already seen would be
        // shorter than intended.
        headBlock = max(headBlock, block)
        let current = headBlock
        Task { [weak self] in
            guard let self, let desk = self.desk else { return }
            for id in await desk.expire(headBlock: current) {
                guard let phase = await desk.phase(of: id) else { continue }
                self.record(id, phase)
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
        defer { connecting = nil }
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
        order.begin()
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
            order.associate(id)
            if let current = await desk.phase(of: id) { order.apply(id: id, phase: current) }
            if order.outcome == .settled { Haptics.success() }
        } catch {
            Haptics.failure()
            localProblem = Self.sentence(for: error)
            order.failLocally()
        }
    }

    func closePosition(_ position: PerplPosition, size: Size? = nil, slippageBps: Int) async {
        localProblem = nil
        order.begin()
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
            order.associate(id)
            if let current = await desk.phase(of: id) { order.apply(id: id, phase: current) }
            if order.outcome == .settled { Haptics.success() }
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
    }

    private func record(_ id: Int64, _ phase: OrderPhase) {
        let before = order.outcome
        order.apply(id: id, phase: phase)
        guard order.outcome != before else { return }
        switch order.outcome {
        case .settled: Haptics.success()
        case .rejected, .expired: Haptics.failure()
        default: break
        }
    }

    private func record(_ event: OrderDesk.Event) {
        switch event {
        case .account(let value):
            account.record(value)
            onAccount?(value)
        case .positions(let value, let isSnapshot):
            let portfolio = isSnapshot
                ? value
                : Self.merging(existing: positions.value ?? [], updates: value)
            positions.record(portfolio)
            onPositions?(portfolio)
        case .order(let id, let phase):
            record(id, phase)
        }
    }

    /// Position updates are deltas, not miniature snapshots. Replacing the array with an
    /// ETH update made an existing BTC position disappear from Desk until reconnect.
    static func merging(
        existing: [PerplPosition], updates: [PerplPosition]
    ) -> [PerplPosition] {
        var result = existing
        for update in updates {
            if let index = result.firstIndex(where: {
                $0.accountID == update.accountID && $0.positionID == update.positionID
            }) {
                result[index] = update
            } else {
                result.append(update)
            }
        }
        return result
    }

    private func socketEnded(id: UUID) {
        guard id == connectionID else { return }
        isConnected = false
        account.recordFailure("The Perpl account stream disconnected.")
        positions.recordFailure("The Perpl position stream disconnected.")
        order.connectionLost()
    }

    /// The venue's sub-reason codes, as sentences.
    ///
    /// `32` is the one worth naming: it means the request id was at or below the last
    /// forwarded one, which is this app's bug rather than the user's, and a generic
    /// "rejected" would send them hunting for a problem with their account.
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
