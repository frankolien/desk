import DeskPerpl
import Foundation

/// An update can arrive before `place` returns the id, so it is held, not judged. A terminal
/// outcome never walks backwards, and only a settlement (not a forward) settles.
public struct OrderProgress: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case sending
        case forwarded
        case settled
        case failed(reason: Int, failure: Int?)
        case unfilled
        case rejected(code: Int, subReason: Int?, error: String? = nil)
        case expired
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
    public private(set) var fill: OrderFill?
    private var frameID: Int64?
    private var held: [Held] = []

    private struct Held: Sendable, Equatable {
        let id: Int64
        let phase: OrderPhase
        let fill: OrderFill?
    }

    public init() {}

    public var isIdle: Bool { outcome == nil }

    public mutating func begin() {
        outcome = .sending
        fill = nil
        frameID = nil
        held.removeAll()
    }

    public mutating func associate(_ id: Int64) {
        frameID = id
        let replay = held
        held.removeAll()
        for update in replay where update.id == id { apply(id: id, phase: update.phase, fill: update.fill) }
    }

    public mutating func apply(id: Int64, phase: OrderPhase, fill: OrderFill? = nil) {
        guard let frameID else {
            // Only while this screen's order is in flight: auto-copy sends through the same
            // desk, and buffering its frames would grow this observed array without bound.
            if outcome != nil { held.append(Held(id: id, phase: phase, fill: fill)) }
            return
        }
        guard id == frameID else { return }
        // The same settlement read twice, once without its fill: keep the fill.
        if outcome == .settled, case .settled = phase {
            if self.fill == nil, let fill { self.fill = fill }
            return
        }
        // Terminal never walks back, except a failure (a later non-failure overturns it) and an
        // expiry, which is Desk's own timeout (orders carry no deadline), so a late answer wins.
        if outcome?.isTerminal == true {
            switch (outcome, phase) {
            case (.failed, .settled), (.failed, .unfilled): break
            case (.expired, .settled), (.expired, .unfilled), (.expired, .failed): break
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

    public mutating func connectionLost() {
        guard outcome?.isBusy == true else { return }
        outcome = .abandoned
    }

    public mutating func failureUnheard() {
        guard case .failed = outcome else { return }
        outcome = .abandoned
    }

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
