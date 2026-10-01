import DeskPerpl
import Foundation

/// Where one order has got to, from a screen's point of view.
///
/// Extracted from the view model because this exact bug has now occurred twice at two
/// different layers: an order's answer arriving before the code that would recognise it
/// was ready. Inside `OrderDesk` it was a status frame landing before the order was
/// tracked; one layer up it was a tracked update landing before `place` had returned the
/// frame id to compare against. Both present identically — a ticket that waits forever on
/// an order that already filled.
///
/// The reason it recurred is that the logic lived in a view model with no tests. It does
/// not any more.
///
/// Three rules, and they are the whole type:
///
///   1. **An update with no id yet is held, not judged.** The window between sending an
///      order and learning its id is real, because the gateway can answer while the send
///      call is still unwinding.
///   2. **A terminal outcome never walks backwards.** Replay and the live watcher can
///      deliver the same phases in either order, and a buffered `sent` applied after a
///      real fill would put the screen back on "sending".
///   3. **Only a settlement settles.** A forwarded acknowledgement is its own outcome,
///      because saying "done" on it tells someone they hold a position they may not.
public struct OrderProgress: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case sending
        /// `mt: 3`, `code: 0`. The gateway has it; the book does not.
        case forwarded
        case settled
        /// The venue refused to post or settle it (`st: 7`); `failure` is Perpl's `fr`.
        case failed(reason: Int, failure: Int?)
        /// Cancelled or expired having filled nothing: for a market order, the book moved
        /// past the slippage bound.
        case unfilled
        case rejected(code: Int, subReason: Int?, error: String? = nil)
        case expired
        /// The socket went away while the order was still in flight, so no answer is
        /// coming. Distinct from a rejection: nobody knows what happened to the order.
        case abandoned

        public var isTerminal: Bool {
            switch self {
            case .sending, .forwarded: false
            case .settled, .failed, .unfilled, .rejected, .expired, .abandoned: true
            }
        }

        public var isBusy: Bool { !isTerminal }
    }

    public private(set) var outcome: Outcome?
    /// What the order filled, from the update that decided it.
    public private(set) var fill: OrderFill?
    private var frameID: Int64?
    private var held: [Held] = []

    /// A named pair rather than a tuple, so the whole type can synthesise `Equatable` —
    /// tuples cannot, and a progress value that two tests cannot compare is a progress
    /// value that goes untested.
    private struct Held: Sendable, Equatable {
        let id: Int64
        let phase: OrderPhase
        let fill: OrderFill?
    }

    public init() {}

    public var isIdle: Bool { outcome == nil }

    /// An order has been handed to the desk but has no id yet.
    public mutating func begin() {
        outcome = .sending
        fill = nil
        frameID = nil
        held.removeAll()
    }

    /// The desk has returned the id. Anything held for it is replayed in arrival order.
    public mutating func associate(_ id: Int64) {
        frameID = id
        let replay = held
        held.removeAll()
        for update in replay where update.id == id { apply(id: id, phase: update.phase, fill: update.fill) }
    }

    /// One update from the socket.
    public mutating func apply(id: Int64, phase: OrderPhase, fill: OrderFill? = nil) {
        guard let frameID else {
            // Only while an order of this screen's is in flight. Auto-copy sends its orders
            // through the same desk, and their frames were buffered here forever: the array
            // grew for the life of the session and, being observed state, invalidated every
            // view reading it on each one.
            if outcome != nil { held.append(Held(id: id, phase: phase, fill: fill)) }
            return
        }
        guard id == frameID else { return }
        // The same settlement read twice, once without its fill: keep the fill.
        if outcome == .settled, case .settled = phase {
            if self.fill == nil, let fill { self.fill = fill }
            return
        }
        // Terminal outcomes never walk back, with one exception the venue documents: a
        // failure is not final while a non-failure for the same order can still follow.
        if outcome?.isTerminal == true {
            guard case .failed = outcome else { return }
            switch phase {
            case .settled, .unfilled: break
            default: return
            }
        }
        outcome = switch phase {
        case .sent: .sending
        case .forwarded: .forwarded
        case .settled: .settled
        case .failed(let reason, let failure): .failed(reason: reason, failure: failure)
        case .unfilled: .unfilled
        case .expired: .expired
        case .rejected(let code, let subReason, let error):
            .rejected(code: code, subReason: subReason, error: error)
        }
        if let fill { self.fill = fill }
    }

    /// The socket ended. Only meaningful while an order is still in flight — an order that
    /// already settled is not abandoned by a connection closing afterwards.
    public mutating func connectionLost() {
        guard outcome?.isBusy == true else { return }
        outcome = .abandoned
    }

    /// A failure raised before the order reached the desk at all.
    public mutating func failLocally() {
        outcome = .rejected(code: 0, subReason: nil, error: nil)
        held.removeAll()
    }

    public mutating func reset() {
        outcome = nil
        fill = nil
        frameID = nil
        held.removeAll()
    }
}
