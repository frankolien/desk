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
        case .rejected(let code, let subReason):
            localProblem ?? Self.reason(code: code, subReason: subReason)
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
    private var frameID: Int64?
    private(set) var isConnected = false
    var onAccount: ((PerplAccount) -> Void)?
    var onPositions: (([PerplPosition]) -> Void)?
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
    func adopt(apiKey: APIKey, session: SigningSession, market: Market) {
        credentials = PerplCredentials(apiKey: apiKey, session: session)
        desk = OrderDesk(socket: .testnet(), market: market)
    }

    /// Rebuilds the order desk for the instrument the person selected. Market discovery
    /// and order construction now share the same Perpl market instead of every row
    /// eventually submitting BTC.
    func selectMarket(_ market: Market) async {
        guard credentials != nil else { return }
        watching?.cancel()
        await desk?.close()
        desk = OrderDesk(socket: .testnet(), market: market)
        isConnected = false
        try? await connect(lastForwarded: 0)
    }

    func noteHeadBlock(_ block: Int64) {
        // Monotonic. The context and the market-state stream can report out of order, and
        // an order deadline computed from an older block than one already seen would be
        // shorter than intended.
        headBlock = max(headBlock, block)
    }

    /// Connects, and begins the single read of the socket.
    func connect(lastForwarded: Int64) async throws {
        guard let desk, let credentials else { throw OrderDesk.Failure.notEnrolled }
        let id = UUID()
        connectionID = id
        try await desk.open(credentials: credentials, lastForwarded: lastForwarded)
        isConnected = true
        watching?.cancel()
        watching = Task { [weak self] in
            for await update in await desk.observe() {
                guard let self else { return }
                await record(update)
            }
            // The stream finishing means the socket went away. An order still in flight
            // has no answer coming, and saying so beats a spinner that never ends.
            await self?.socketEnded(id: id)
        }
    }

    func reconnect() async {
        guard credentials != nil else { return }
        watching?.cancel()
        await desk?.close()
        isConnected = false
        try? await connect(lastForwarded: 0)
    }

    func close() async {
        connectionID = UUID()
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
                try await connect(lastForwarded: 0)
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
        case .positions(let value):
            positions.record(value)
            onPositions?(value)
        case .order(let id, let phase):
            record(id, phase)
        }
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
            return "Your trading key has expired. Sign in with Face ID and try again."
        case let url as URLError:
            return url.code == .notConnectedToInternet
                ? "Your phone is offline. Nothing was sent."
                : "The network interrupted the Perpl connection. Nothing was sent; try again."
        default:
            return "The order could not be sent. Nothing left your phone (\(String(describing: error)))."
        }
    }
}
