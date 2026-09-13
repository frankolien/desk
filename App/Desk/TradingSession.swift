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
    /// Where an order is, as the ticket needs to render it.
    enum Progress: Equatable {
        case sending
        /// `mt: 3`, `code: 0`. The gateway has it; the book does not. Its own state,
        /// because collapsing it into "done" tells someone they hold a position they may
        /// not.
        case forwarded
        case filled
        case rejected(String)

        var isBusy: Bool { self == .sending || self == .forwarded }
    }

    private(set) var progress: Progress?
    /// The block the venue most recently reported. An order's deadline is computed
    /// against it, so a stale one produces an order that expires on arrival.
    private(set) var headBlock: Int64 = 0

    private var desk: OrderDesk?
    private var credentials: PerplCredentials?
    private var watching: Task<Void, Never>?
    private var frameID: Int64?

    /// Called once a desk has been opened and enrolled. Until then there is nothing to
    /// connect with, which is a state rather than a fault.
    func adopt(apiKey: APIKey, session: SigningSession, market: Market) {
        credentials = PerplCredentials(apiKey: apiKey, session: session)
        desk = OrderDesk(socket: .testnet(), market: market)
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
        try await desk.open(credentials: credentials, lastForwarded: lastForwarded)
        watching?.cancel()
        watching = Task { [weak self] in
            for await update in await desk.observe() {
                guard let self else { return }
                await record(update.frameID, update.phase)
            }
            // The stream finishing means the socket went away. An order still in flight
            // has no answer coming, and saying so beats a spinner that never ends.
            await self?.socketEnded()
        }
    }

    /// Sends the order, or explains why it cannot be sent.
    ///
    /// Every failure is a sentence naming what the user can do next. Nothing here reports
    /// success on anything short of `mt: 24`.
    func place(_ draft: OrderDesk.Draft) async {
        progress = .sending
        do {
            guard let desk else { throw OrderDesk.Failure.notEnrolled }
            frameID = try await desk.place(draft, headBlock: headBlock)
        } catch {
            Haptics.failure()
            progress = .rejected(Self.sentence(for: error))
        }
    }

    func clear() { progress = nil; frameID = nil }

    private func record(_ id: Int64, _ phase: OrderPhase) {
        guard id == frameID else { return }
        switch phase {
        case .sent:
            progress = .sending
        case .forwarded:
            progress = .forwarded
        case .rejected(let code, let subReason):
            Haptics.failure()
            progress = .rejected(Self.reason(code: code, subReason: subReason))
        case .settled:
            Haptics.success()
            progress = .filled
        case .expired:
            progress = .rejected(
                "The order expired before it reached the book. Nothing was filled.")
        }
    }

    private func socketEnded() {
        guard progress?.isBusy == true else { return }
        progress = .rejected(
            "The connection to Perpl dropped before the order settled. "
                + "Check your position before sending another.")
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
        case SigningSession.Failure.closed:
            return "Your trading key has expired. Sign in with Face ID and try again."
        default:
            return "The order could not be sent. Nothing left your phone."
        }
    }
}
