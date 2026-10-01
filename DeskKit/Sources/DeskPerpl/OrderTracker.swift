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
    /// `mt: 24` with a non-failure status: the venue posted it and it did something —
    /// filled in full or in part, or rests on the book, or waits for its trigger. What it
    /// filled is `OrderTracker.fill(of:)`.
    case settled
    /// `mt: 24` with `st: 7`. The venue refused to post or settle it: `reason` (`sr`) says
    /// where, `failure` (`fr`) why. Nothing changed on the book.
    case failed(reason: Int, failure: Int?)
    /// `mt: 24`, cancelled or expired having filled nothing. A market order is an
    /// immediate-or-cancel limit at the slippage bound, so a book that has moved past the
    /// bound ends here.
    case unfilled
    /// The deadline block passed with no update. The order is gone, and saying so is
    /// better than a spinner that never ends.
    case expired

    public var isTerminal: Bool {
        switch self {
        case .sent, .forwarded: false
        case .rejected, .settled, .failed, .unfilled, .expired: true
        }
    }

    /// Whether a screen may claim the order did something to the position.
    public var hasReachedTheBook: Bool {
        if case .settled = self { return true }
        return false
    }
}

/// What an order did, from the venue's own update. Raw integers at the market's scales.
public struct OrderFill: Sendable, Hashable {
    /// `st`, the venue's OrderStatus.
    public let status: Int
    /// `os`, the size the order asked for.
    public let originalRaw: Int64
    /// `fs`, the size it filled.
    public let filledRaw: Int64
    /// `fp`, the size-weighted average fill price; zero when nothing filled.
    public let priceRaw: Int64
    /// `f`, the fee paid, gross of any builder fee.
    public let feeRaw: Int64
    /// `t`, the OrderType: 3 and 4 close a position.
    public let orderType: Int

    public init(status: Int, originalRaw: Int64, filledRaw: Int64, priceRaw: Int64, feeRaw: Int64, orderType: Int = 0) {
        self.status = status
        self.originalRaw = originalRaw
        self.filledRaw = filledRaw
        self.priceRaw = priceRaw
        self.feeRaw = feeRaw
        self.orderType = orderType
    }

    public var isClose: Bool { orderType == 3 || orderType == 4 }
    public var isComplete: Bool { originalRaw > 0 && filledRaw >= originalRaw }
    public var isPartial: Bool { filledRaw > 0 && !isComplete }
}

/// Follows orders from send to outcome, over a socket that reports both out of order and
/// more than once.
///
/// An order can get several `mt: 24` updates. Perpl's rule, followed here: the first
/// non-failure status (`st` 2–6, 8–10) is definitive and everything after it is ignored;
/// if only failures (`st: 7`) arrive, the first one stands.
public actor OrderTracker {
    public enum Failure: Error, Sendable, Equatable {
        case frameIDMustBeNonZero
        case unknownFrame(Int64)
    }

    private struct Entry {
        var phase: OrderPhase
        let requestID: Int64
        let deadlineBlock: Int64
        /// A non-failure update has been applied; nothing after it counts.
        var decided = false
        var fill: OrderFill?
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

    /// Size, price and fee from the update that decided the order, when there was one.
    public func fill(of frameID: Int64) -> OrderFill? { entries[frameID]?.fill }

    /// The block after which Desk stops waiting for this order. Desk's own timeout: orders
    /// go out with `lb: 0`, so the venue enforces none, and its answer may still follow.
    public func deadline(of frameID: Int64) -> Int64? { entries[frameID]?.deadlineBlock }

    public var pending: [Int64] {
        entries.filter { !$0.value.phase.isTerminal }.keys.sorted()
    }

    /// Every order a frame moved. An `mt: 24` frame can carry an opening order and its
    /// stop and take profit together; `apply` alone reports only the first of them.
    public func applyAll(_ frame: InboundFrame) -> [Int64] {
        guard frame.kind == .orderUpdate,
              let root = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
              let items = root["d"] as? [Any], items.count > 1 else {
            return apply(frame).map { [$0] } ?? []
        }
        var moved: [Int64] = []
        for item in items {
            guard let payload = try? JSONSerialization.data(withJSONObject: ["mt": 24, "d": [item]]),
                  let single = try? InboundFrame(payload: payload),
                  let id = apply(single), !moved.contains(id) else { continue }
            moved.append(id)
        }
        return moved
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
            struct Batch: Decodable { let d: [OrderUpdate] }

            // v235 sends `{mt:24,d:[{rq:...}]}`. Older captures used a root `sn`.
            let update = (try? frame.decode(Batch.self).d.first { item in
                guard let requestID = item.rq else { return false }
                return entries.values.contains { $0.requestID == requestID }
            }) ?? (try? frame.decode(OrderUpdate.self))
            guard let update else { return nil }
            let frameID: Int64?
            if let requestID = update.rq {
                frameID = entries.first { $0.value.requestID == requestID }?.key
            } else {
                frameID = update.sn
            }
            guard let frameID, var entry = entries[frameID], !entry.decided else { return nil }
            // A gateway rejection (mt 3) or a first failure is not the last word: the venue
            // is the authority on its own book, so a later non-failure still decides it.
            switch update.st {
            case nil:
                // Captures from before orders carried a status. The old reading stands.
                entry.phase = .settled
                entry.decided = true
            case 0, 1:
                // Unspecified or pending: the order is on its way, not yet anywhere.
                return nil
            case 7:
                if case .failed = entry.phase { return nil }
                entry.phase = .failed(reason: update.sr ?? 0, failure: update.fr)
            case let status?:
                let fill = OrderFill(
                    status: status, originalRaw: update.os ?? 0, filledRaw: update.fs ?? 0,
                    priceRaw: update.fp ?? 0, feeRaw: update.f ?? 0, orderType: update.t ?? 0)
                entry.fill = fill
                entry.decided = true
                entry.phase = (status == 5 || status == 6) && fill.filledRaw == 0 ? .unfilled : .settled
            }
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

/// One order in an `mt: 24` frame. Sizes, prices and fees arrive as numbers or as strings
/// depending on their magnitude, so each is read either way.
struct OrderUpdate: Decodable {
    let sn: Int64?
    let rq: Int64?
    let st: Int?
    let sr: Int?
    let fr: Int?
    let os: Int64?
    let fs: Int64?
    let fp: Int64?
    let f: Int64?
    let t: Int?

    private enum CodingKeys: String, CodingKey { case sn, rq, st, sr, fr, os, fs, fp, f, t }

    init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        func number(_ key: CodingKeys) -> Int64? {
            (try? box.decode(Int64.self, forKey: key)) ?? (try? box.decode(String.self, forKey: key)).flatMap(Int64.init)
        }
        sn = number(.sn)
        rq = number(.rq)
        st = number(.st).map(Int.init)
        sr = number(.sr).map(Int.init)
        fr = number(.fr).map(Int.init)
        os = number(.os)
        fs = number(.fs)
        fp = number(.fp)
        f = number(.f)
        t = number(.t).map(Int.init)
    }
}
