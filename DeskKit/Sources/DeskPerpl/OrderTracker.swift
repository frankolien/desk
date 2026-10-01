import Foundation

/// `mt: 3` with `code: 0` means accepted for forwarding, not filled. Only `mt: 24` settles
/// an order; only a non-zero `mt: 3` may fail fast, since no `mt: 24` follows it.
public enum OrderPhase: Sendable, Hashable {
    case sent
    case forwarded
    case rejected(code: Int, subReason: Int?, error: String? = nil)
    case settled
    case failed(reason: Int, failure: Int?)
    case unfilled
    case expired

    public var isTerminal: Bool {
        switch self {
        case .sent, .forwarded: false
        case .rejected, .settled, .failed, .unfilled, .expired: true
        }
    }

    public var hasReachedTheBook: Bool {
        if case .settled = self { return true }
        return false
    }
}

public struct OrderFill: Sendable, Hashable {
    public let status: Int
    public let originalRaw: Int64
    public let filledRaw: Int64
    public let priceRaw: Int64
    public let feeRaw: Int64
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

/// Perpl's rule: the first non-failure `mt: 24` status (`st` 2–6, 8–10) is definitive and
/// later ones are ignored; if only failures (`st: 7`) arrive, the first one stands.
public actor OrderTracker {
    public enum Failure: Error, Sendable, Equatable {
        case frameIDMustBeNonZero
        case unknownFrame(Int64)
    }

    private struct Entry {
        var phase: OrderPhase
        let requestID: Int64
        let deadlineBlock: Int64
        var decided = false
        var fill: OrderFill?
    }

    private var entries: [Int64: Entry] = [:]

    public init() {}

    /// A zero frame id is omitted from the status response, so its outcome could never be
    /// correlated.
    public func track(frameID: Int64, requestID: Int64? = nil, deadlineBlock: Int64) throws {
        guard frameID != 0 else { throw Failure.frameIDMustBeNonZero }
        entries[frameID] = Entry(
            phase: .sent,
            requestID: requestID ?? frameID,
            deadlineBlock: deadlineBlock)
        prune()
    }

    private func prune() {
        guard entries.count > Self.retained else { return }
        let finished = entries.filter { $0.value.phase.isTerminal }.keys.sorted()
        for frameID in finished.prefix(entries.count - Self.retained) {
            entries.removeValue(forKey: frameID)
        }
    }

    private static let retained = 64

    public func phase(of frameID: Int64) -> OrderPhase? { entries[frameID]?.phase }

    public func fill(of frameID: Int64) -> OrderFill? { entries[frameID]?.fill }

    /// Desk's own timeout: orders go out with `lb: 0`, so the venue's answer may still follow.
    public func deadline(of frameID: Int64) -> Int64? { entries[frameID]?.deadlineBlock }

    public var pending: [Int64] {
        entries.filter { !$0.value.phase.isTerminal }.keys.sorted()
    }

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
                entry.phase = .settled
                entry.decided = true
            case 0, 1:
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

/// Sizes, prices and fees arrive as numbers or strings depending on magnitude.
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
