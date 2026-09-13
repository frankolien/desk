import Foundation

/// Where an order has actually got to.
///
/// The distinction this type exists for: `mt: 3` with `code: 0` means *accepted for
/// forwarding*. Not posted, not filled. A screen that reads it as a fill tells the user
/// they have a position they may not have, which is the worst lie this app could tell.
/// Only `mt: 24` settles an order, and only a non-zero `mt: 3` may fail fast — because
/// that is the one case where no `mt: 24` is coming.
public enum OrderPhase: Sendable, Hashable {
    /// Sent, nothing back yet.
    case sent
    /// `mt: 3`, `code: 0`. The gateway has it. Nothing has happened on the book.
    case forwarded
    /// `mt: 3`, non-zero. Terminal: no update will follow.
    case rejected(code: Int, subReason: Int?)
    /// `mt: 24`. The only frame that settles anything.
    case settled
    /// The deadline block passed with no update. The order is gone, and saying so is
    /// better than a spinner that never ends.
    case expired

    public var isTerminal: Bool {
        switch self {
        case .sent, .forwarded: false
        case .rejected, .settled, .expired: true
        }
    }

    /// Whether a screen may claim the order did something to the position.
    public var hasReachedTheBook: Bool {
        if case .settled = self { return true }
        return false
    }
}

/// Follows orders from send to outcome, over a socket that reports both out of order and
/// more than once.
public actor OrderTracker {
    public enum Failure: Error, Sendable, Equatable {
        case frameIDMustBeNonZero
        case unknownFrame(Int64)
    }

    private struct Entry {
        var phase: OrderPhase
        let deadlineBlock: Int64
    }

    private var entries: [Int64: Entry] = [:]

    public init() {}

    /// A zero frame id is omitted from the status response, so an order carrying one can
    /// never be correlated with its outcome. `OrderBuilder` refuses to make one; this
    /// refuses to track one.
    public func track(frameID: Int64, deadlineBlock: Int64) throws {
        guard frameID != 0 else { throw Failure.frameIDMustBeNonZero }
        entries[frameID] = Entry(phase: .sent, deadlineBlock: deadlineBlock)
    }

    public func phase(of frameID: Int64) -> OrderPhase? { entries[frameID]?.phase }

    public var pending: [Int64] {
        entries.filter { !$0.value.phase.isTerminal }.keys.sorted()
    }

    /// Applies an inbound frame. Unknown frame types and frames for orders we are not
    /// following are ignored rather than treated as errors — the socket carries a great
    /// deal that is not about us.
    @discardableResult
    public func apply(_ frame: InboundFrame) -> Int64? {
        switch frame.kind {
        case .orderStatus:
            guard let status = try? frame.decode(OrderStatus.self),
                  let frameID = status.frameID,
                  var entry = entries[frameID]
            else { return nil }
            // A terminal phase is never walked back: a late duplicate status must not
            // turn a settled order back into a pending one.
            guard !entry.phase.isTerminal else { return frameID }
            entry.phase = status.isAccepted
                ? .forwarded
                : .rejected(code: status.code, subReason: status.subReason)
            entries[frameID] = entry
            return frameID

        case .orderUpdate:
            struct Update: Decodable { let sn: Int64? }
            guard let update = try? frame.decode(Update.self), let frameID = update.sn,
                  var entry = entries[frameID]
            else { return nil }
            // An update settles even an order we had already written off as rejected —
            // the venue is the authority on its own book, not our state machine.
            entry.phase = .settled
            entries[frameID] = entry
            return frameID

        default:
            return nil
        }
    }

    /// Anything still unsettled past its deadline block is gone. Called as the head block
    /// advances, which the market feed already reports.
    public func expire(headBlock: Int64) -> [Int64] {
        var expired: [Int64] = []
        for (frameID, entry) in entries where !entry.phase.isTerminal {
            guard headBlock > entry.deadlineBlock else { continue }
            entries[frameID]?.phase = .expired
            expired.append(frameID)
        }
        return expired.sorted()
    }

    public func forget(_ frameID: Int64) { entries.removeValue(forKey: frameID) }
}
