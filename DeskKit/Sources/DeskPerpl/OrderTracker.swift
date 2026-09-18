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
    case rejected(code: Int, subReason: Int?, error: String? = nil)
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
        let requestID: Int64
        let deadlineBlock: Int64
    }

    private var entries: [Int64: Entry] = [:]

    public init() {}

    /// A zero frame id is omitted from the status response, so an order carrying one can
    /// never be correlated with its outcome. `OrderBuilder` refuses to make one; this
    /// refuses to track one.
    public func track(frameID: Int64, requestID: Int64? = nil, deadlineBlock: Int64) throws {
        guard frameID != 0 else { throw Failure.frameIDMustBeNonZero }
        entries[frameID] = Entry(
            phase: .sent,
            requestID: requestID ?? frameID,
            deadlineBlock: deadlineBlock)
        prune()
    }

    /// Finished orders are kept only while something might still ask about them.
    ///
    /// Nothing forgot a settled order: `forget` is called when a send fails and never when
    /// one succeeds, so auto-copy — which sends an order, a stop and a take profit per copy
    /// — grew this map for the life of the session, and every socket frame and every head
    /// block walked all of it.
    private func prune() {
        guard entries.count > Self.retained else { return }
        let finished = entries.filter { $0.value.phase.isTerminal }.keys.sorted()
        for frameID in finished.prefix(entries.count - Self.retained) {
            entries.removeValue(forKey: frameID)
        }
    }

    /// Enough to answer every caller that polls after a settlement, and to keep the map
    /// small enough that scanning it stays free.
    private static let retained = 64

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
                : .rejected(code: status.code, subReason: status.subReason, error: status.error)
            entries[frameID] = entry
            return frameID

        case .orderUpdate:
            struct Update: Decodable {
                let sn: Int64?
                let rq: Int64?
            }
            struct Batch: Decodable { let d: [Update] }

            // v235 sends `{mt:24,d:[{rq:...}]}`. Older captures used a root `sn`.
            let update = (try? frame.decode(Batch.self).d.first { item in
                guard let requestID = item.rq else { return false }
                return entries.values.contains { $0.requestID == requestID }
            }) ?? (try? frame.decode(Update.self))
            guard let update else { return nil }
            let frameID: Int64?
            if let requestID = update.rq {
                frameID = entries.first { $0.value.requestID == requestID }?.key
            } else {
                frameID = update.sn
            }
            guard let frameID, var entry = entries[frameID] else { return nil }
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
