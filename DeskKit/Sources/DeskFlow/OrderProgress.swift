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
        case rejected(code: Int, subReason: Int?, error: String? = nil)
        case expired
        /// The socket went away while the order was still in flight, so no answer is
        /// coming. Distinct from a rejection: nobody knows what happened to the order.
        case abandoned

        public var isTerminal: Bool {
            switch self {
            case .sending, .forwarded: false
            case .settled, .rejected, .expired, .abandoned: true
            }
        }

        public var isBusy: Bool { !isTerminal }
    }

    public private(set) var outcome: Outcome?
    private var frameID: Int64?
    private var held: [Held] = []

    /// A named pair rather than a tuple, so the whole type can synthesise `Equatable` —
    /// tuples cannot, and a progress value that two tests cannot compare is a progress
    /// value that goes untested.
    private struct Held: Sendable, Equatable {
        let id: Int64
        let phase: OrderPhase
    }

    public init() {}

    public var isIdle: Bool { outcome == nil }

    /// An order has been handed to the desk but has no id yet.
    public mutating func begin() {
        outcome = .sending
        frameID = nil
        held.removeAll()
    }

    /// The desk has returned the id. Anything held for it is replayed in arrival order.
    public mutating func associate(_ id: Int64) {
        frameID = id
        let replay = held
        held.removeAll()
        for update in replay where update.id == id { apply(id: id, phase: update.phase) }
    }

    /// One update from the socket.
    public mutating func apply(id: Int64, phase: OrderPhase) {
        guard let frameID else {
            held.append(Held(id: id, phase: phase))
            return
        }
        guard id == frameID, outcome?.isTerminal != true else { return }
        outcome = switch phase {
        case .sent: .sending
        case .forwarded: .forwarded
        case .settled: .settled
        case .expired: .expired
        case .rejected(let code, let subReason, let error):
            .rejected(code: code, subReason: subReason, error: error)
        }
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
    }

    public mutating func reset() {
        outcome = nil
        frameID = nil
        held.removeAll()
    }
}
