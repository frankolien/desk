import Foundation
import Testing

@testable import DeskPerpl

@Suite("Order outcomes")
struct OrderTrackerTests {
    @Test("The version-235 batched order update settles by request id")
    func compactBatchedUpdateSettlesByRequestID() async throws {
        let tracker = OrderTracker()
        try await tracker.track(frameID: 7, requestID: 42, deadlineBlock: 100)
        let frame = try InboundFrame(
            payload: Data(#"{"mt":24,"d":[{"oid":900,"rq":42,"st":3}]}"#.utf8))

        #expect(await tracker.apply(frame) == 7)
        #expect(await tracker.phase(of: 7) == .settled)
    }

    private func frame(_ json: String) throws -> InboundFrame {
        try InboundFrame(payload: Data(json.utf8))
    }

    private func tracked() async throws -> OrderTracker {
        let tracker = OrderTracker()
        try await tracker.track(frameID: 1, deadlineBlock: 120)
        return tracker
    }

    @Test("A forwarded order has not reached the book")
    func forwardedIsNotFilled() async throws {
        // The trap the whole type exists for. `code: 0` on mt 3 means the gateway
        // accepted it for forwarding — not posted, not filled. A screen reading this as
        // a fill tells the user they hold a position they may not hold.
        let tracker = try await tracked()
        await tracker.apply(try frame(#"{"mt":3,"sn":1,"code":0}"#))
        #expect(await tracker.phase(of: 1) == .forwarded)
        #expect(await tracker.phase(of: 1)?.hasReachedTheBook == false)
        #expect(await tracker.phase(of: 1)?.isTerminal == false)
        #expect(await tracker.pending == [1])
    }

    @Test("Only an update settles an order")
    func updateSettles() async throws {
        let tracker = try await tracked()
        await tracker.apply(try frame(#"{"mt":3,"sn":1,"code":0}"#))
        await tracker.apply(try frame(#"{"mt":24,"sn":1,"oid":9981}"#))
        #expect(await tracker.phase(of: 1) == .settled)
        #expect(await tracker.phase(of: 1)?.hasReachedTheBook == true)
        #expect(await tracker.pending.isEmpty)
    }

    @Test("A non-zero status is the one case that may fail fast")
    func rejectionIsTerminal() async throws {
        // 34 is order forwarding still disabled: an opening-sequence bug, not a trading
        // one, and no update will follow it.
        let tracker = try await tracked()
        await tracker.apply(try frame(#"{"mt":3,"sn":1,"code":1,"sr":34}"#))
        #expect(await tracker.phase(of: 1) == .rejected(code: 1, subReason: 34))
        #expect(await tracker.phase(of: 1)?.isTerminal == true)
        #expect(await tracker.phase(of: 1)?.hasReachedTheBook == false)
    }

    @Test("A late duplicate status cannot walk a settled order backwards")
    func terminalIsSticky() async throws {
        // The socket reports out of order and more than once.
        let tracker = try await tracked()
        await tracker.apply(try frame(#"{"mt":24,"sn":1}"#))
        await tracker.apply(try frame(#"{"mt":3,"sn":1,"code":0}"#))
        #expect(await tracker.phase(of: 1) == .settled)
    }

    @Test("An update settles an order we had written off")
    func updateOverridesRejection() async throws {
        // The venue is the authority on its own book, not our state machine.
        let tracker = try await tracked()
        await tracker.apply(try frame(#"{"mt":3,"sn":1,"code":2,"sr":7}"#))
        await tracker.apply(try frame(#"{"mt":24,"sn":1}"#))
        #expect(await tracker.phase(of: 1) == .settled)
    }

    @Test("An order past its deadline block is gone, not pending forever")
    func expiry() async throws {
        let tracker = try await tracked()
        await tracker.apply(try frame(#"{"mt":3,"sn":1,"code":0}"#))
        #expect(await tracker.expire(headBlock: 120).isEmpty)
        #expect(await tracker.expire(headBlock: 121) == [1])
        #expect(await tracker.phase(of: 1) == .expired)
        // And a settled order is never expired out from under itself.
        try await tracker.track(frameID: 2, deadlineBlock: 50)
        await tracker.apply(try frame(#"{"mt":24,"sn":2}"#))
        #expect(await tracker.expire(headBlock: 9_999).isEmpty)
    }

    @Test("Frames for orders we are not following are ignored, not errors")
    func ignoresOtherTraffic() async throws {
        let tracker = try await tracked()
        #expect(await tracker.apply(try frame(#"{"mt":3,"sn":77,"code":0}"#)) == nil)
        #expect(await tracker.apply(try frame(#"{"mt":19,"accounts":[]}"#)) == nil)
        #expect(await tracker.apply(try frame(#"{"mt":4242,"anything":1}"#)) == nil)
        #expect(await tracker.phase(of: 1) == .sent)
    }

    @Test("Finished orders are forgotten in order, and orders still in flight are not")
    func boundedMemory() async throws {
        let tracker = OrderTracker()
        // Auto-copy sends three frames per copy — the order, its stop and its take profit —
        // and nothing forgot them, so the map grew for the life of the session.
        for frameID in 1...200 {
            try await tracker.track(frameID: Int64(frameID), deadlineBlock: 10_000)
            _ = await tracker.apply(try frame(#"{"mt":24,"rq":\#(frameID),"pid":7}"#))
        }
        // One left in flight, which must survive however much settles after it.
        try await tracker.track(frameID: 500, deadlineBlock: 10_000)
        for frameID in 201...260 {
            try await tracker.track(frameID: Int64(frameID), deadlineBlock: 10_000)
            _ = await tracker.apply(try frame(#"{"mt":24,"rq":\#(frameID),"pid":7}"#))
        }
        #expect(await tracker.phase(of: 500) == .sent)
        #expect(await tracker.phase(of: 1) == nil)
        #expect(await tracker.phase(of: 260) == .settled)
    }

    @Test("A zero frame id is refused, because it can never be correlated")
    func zeroFrameID() async {
        let tracker = OrderTracker()
        await #expect(throws: OrderTracker.Failure.frameIDMustBeNonZero) {
            try await tracker.track(frameID: 0, deadlineBlock: 100)
        }
    }
}

@Suite("Order outcomes follow the venue's status")
struct OrderStatusRulesTests {
    private func frame(_ json: String) throws -> InboundFrame { try InboundFrame(payload: Data(json.utf8)) }

    private func tracker(_ frames: Int64...) async throws -> OrderTracker {
        let tracker = OrderTracker()
        for id in frames { try await tracker.track(frameID: id, requestID: id, deadlineBlock: 1_000) }
        return tracker
    }

    @Test("A failed update is a failure with its reasons, never a fill")
    func failureIsNotAFill() async throws {
        // The bug this suite exists for: every update used to read as "Filled".
        let tracker = try await tracker(1)
        await tracker.apply(try frame(#"{"mt":24,"d":[{"rq":1,"st":7,"sr":44,"fr":8,"os":"1000","fs":"0"}]}"#))
        #expect(await tracker.phase(of: 1) == .failed(reason: 44, failure: 8))
        #expect(await tracker.phase(of: 1)?.hasReachedTheBook == false)
        #expect(await tracker.phase(of: 1)?.isTerminal == true)
        #expect(await tracker.fill(of: 1) == nil)
    }

    @Test("Forwarding off arrives as a failed update, not a gateway rejection")
    func forwardingOffOnUpdate() async throws {
        let tracker = try await tracker(1)
        await tracker.apply(try frame(#"{"mt":24,"d":[{"rq":1,"st":7,"sr":34}]}"#))
        #expect(await tracker.phase(of: 1) == .failed(reason: 34, failure: nil))
    }

    @Test("A later non-failure decides an order that first failed; the first failure otherwise stands")
    func failureThenSuccess() async throws {
        let tracker = try await tracker(1, 2)
        await tracker.apply(try frame(#"{"mt":24,"d":[{"rq":1,"st":7,"sr":36,"fr":7}]}"#))
        await tracker.apply(try frame(#"{"mt":24,"d":[{"rq":1,"st":4,"os":10,"fs":10,"fp":8312050,"f":350000}]}"#))
        #expect(await tracker.phase(of: 1) == .settled)
        #expect(await tracker.fill(of: 1)?.isComplete == true)

        await tracker.apply(try frame(#"{"mt":24,"d":[{"rq":2,"st":7,"sr":36,"fr":7}]}"#))
        await tracker.apply(try frame(#"{"mt":24,"d":[{"rq":2,"st":7,"sr":44,"fr":1}]}"#))
        #expect(await tracker.phase(of: 2) == .failed(reason: 36, failure: 7))
    }

    @Test("The first non-failure is definitive; a failure after it is ignored")
    func successThenFailure() async throws {
        let tracker = try await tracker(1)
        await tracker.apply(try frame(#"{"mt":24,"d":[{"rq":1,"st":4,"os":10,"fs":10}]}"#))
        await tracker.apply(try frame(#"{"mt":24,"d":[{"rq":1,"st":7,"sr":44,"fr":1}]}"#))
        #expect(await tracker.phase(of: 1) == .settled)
    }

    @Test("A market order that filled nothing within its bound is unfilled")
    func iocWithNoFill() async throws {
        let tracker = try await tracker(1, 2)
        await tracker.apply(try frame(#"{"mt":24,"d":[{"rq":1,"st":5,"sr":16,"os":10,"fs":0,"t":3}]}"#))
        #expect(await tracker.phase(of: 1) == .unfilled)
        #expect(await tracker.fill(of: 1)?.isClose == true)
        await tracker.apply(try frame(#"{"mt":24,"d":[{"rq":2,"st":6,"os":10}]}"#))
        #expect(await tracker.phase(of: 2) == .unfilled)
    }

    @Test("A partial fill settles with the size it filled, its price and its fee, numbers or strings")
    func partialFill() async throws {
        let tracker = try await tracker(1)
        await tracker.apply(try frame(#"{"mt":24,"d":[{"rq":1,"st":5,"sr":16,"os":"12000","fs":"8000","fp":"8312050","f":"240000","t":1}]}"#))
        #expect(await tracker.phase(of: 1) == .settled)
        let fill = try #require(await tracker.fill(of: 1))
        #expect(fill.isPartial)
        #expect(!fill.isComplete)
        #expect(fill.filledRaw == 8_000 && fill.originalRaw == 12_000)
        #expect(fill.priceRaw == 8_312_050 && fill.feeRaw == 240_000)
        #expect(!fill.isClose)
    }

    @Test("Pending and unspecified updates leave the order in flight")
    func pendingIsNotAnOutcome() async throws {
        let tracker = try await tracker(1)
        #expect(await tracker.apply(try frame(#"{"mt":24,"d":[{"rq":1,"st":1}]}"#)) == nil)
        #expect(await tracker.phase(of: 1) == .sent)
        #expect(await tracker.pending == [1])
    }

    @Test("One frame carrying two of our orders moves both")
    func batchWithTwoOrders() async throws {
        // An opening order and its stop can arrive together; the stop used to be dropped.
        let tracker = try await tracker(1, 2)
        let moved = await tracker.applyAll(try frame(#"{"mt":24,"d":[{"rq":1,"st":4,"os":5,"fs":5},{"rq":2,"st":8,"os":5,"fs":0},{"rq":99,"st":4}]}"#))
        #expect(moved == [1, 2])
        #expect(await tracker.phase(of: 1) == .settled)
        #expect(await tracker.phase(of: 2) == .settled)
    }
}
