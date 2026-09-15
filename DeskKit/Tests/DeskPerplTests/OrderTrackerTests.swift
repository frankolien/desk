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

    @Test("A zero frame id is refused, because it can never be correlated")
    func zeroFrameID() async {
        let tracker = OrderTracker()
        await #expect(throws: OrderTracker.Failure.frameIDMustBeNonZero) {
            try await tracker.track(frameID: 0, deadlineBlock: 100)
        }
    }
}
