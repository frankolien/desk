import DeskPerpl
import Foundation
import Testing

@testable import DeskFlow

@Suite("Following one order")
struct OrderProgressTests {
    /// The bug this type was extracted for, at the layer where it was found. `place`
    /// tracks and sends, the gateway answers while the send call is still unwinding, and
    /// the update arrives before there is any id to compare it against. Discarded, the
    /// screen waits forever on an order that already filled.
    @Test("An update that arrives before the id is not lost")
    func updateBeforeAssociation() {
        var progress = OrderProgress()
        progress.begin()

        // The answer beats the id home.
        progress.apply(id: 1, phase: .settled)
        #expect(progress.outcome == .sending, "nothing can be concluded yet")

        progress.associate(1)
        #expect(progress.outcome == .settled)
    }

    @Test("Several early updates replay in the order they arrived")
    func replayInOrder() {
        var progress = OrderProgress()
        progress.begin()
        progress.apply(id: 7, phase: .forwarded)
        progress.apply(id: 7, phase: .settled)
        progress.associate(7)
        #expect(progress.outcome == .settled)
    }

    /// Held updates belong to whichever order they name. A frame id from a previous order
    /// must not settle this one.
    @Test("A held update for another order is discarded on association")
    func heldUpdateForAnotherOrder() {
        var progress = OrderProgress()
        progress.begin()
        progress.apply(id: 99, phase: .settled)
        progress.associate(1)
        #expect(progress.outcome == .sending)
    }

    /// Replay and the live watcher can deliver the same phases in either order. Without
    /// this rule a buffered `sent` applied after a real fill puts the screen back on
    /// "sending", which is the same broken spinner by another route.
    @Test("A terminal outcome never walks backwards")
    func terminalIsFinal() {
        var progress = OrderProgress()
        progress.begin()
        progress.associate(1)
        progress.apply(id: 1, phase: .settled)
        progress.apply(id: 1, phase: .sent)
        progress.apply(id: 1, phase: .forwarded)
        #expect(progress.outcome == .settled)
    }

    /// `mt: 3` with `code: 0` means the gateway took the order, not that it filled. The
    /// two must stay distinguishable or a screen claims a position that may not exist.
    @Test("Forwarded is its own outcome and is not terminal")
    func forwardedIsNotSettled() {
        var progress = OrderProgress()
        progress.begin()
        progress.associate(1)
        progress.apply(id: 1, phase: .forwarded)
        #expect(progress.outcome == .forwarded)
        #expect(progress.outcome?.isTerminal == false)
        #expect(progress.outcome?.isBusy == true)
    }

    @Test("A rejection carries its codes through")
    func rejectionCodes() {
        var progress = OrderProgress()
        progress.begin()
        progress.associate(1)
        progress.apply(id: 1, phase: .rejected(code: 4, subReason: 32))
        #expect(progress.outcome == .rejected(code: 4, subReason: 32))
    }

    /// A dropped socket while an order is in flight is not a rejection — nobody knows what
    /// happened to it, and the user has to be told that rather than told it failed.
    @Test("A lost connection abandons an order still in flight")
    
    func connectionLostWhileBusy() {
        var progress = OrderProgress()
        progress.begin()
        progress.associate(1)
        progress.apply(id: 1, phase: .forwarded)
        progress.connectionLost()
        #expect(progress.outcome == .abandoned)
    }

    /// But a connection closing after a fill has settled changes nothing. Sockets close
    /// all the time; an order that already filled is not in doubt.
    @Test("A lost connection after settlement changes nothing")
    func connectionLostAfterSettlement() {
        var progress = OrderProgress()
        progress.begin()
        progress.associate(1)
        progress.apply(id: 1, phase: .settled)
        progress.connectionLost()
        #expect(progress.outcome == .settled)
    }

    @Test("A connection lost while idle is not an order failure")
    func connectionLostWhileIdle() {
        var progress = OrderProgress()
        progress.connectionLost()
        #expect(progress.outcome == nil)
    }

    /// A second order must not inherit the first one's answer, nor its held updates.
    @Test("Beginning again forgets everything about the last order")
    func beginClearsPreviousOrder() {
        var progress = OrderProgress()
        progress.begin()
        progress.associate(1)
        progress.apply(id: 1, phase: .settled)

        progress.begin()
        #expect(progress.outcome == .sending)
        // The previous order's id must no longer match anything.
        progress.apply(id: 1, phase: .settled)
        progress.associate(2)
        #expect(progress.outcome == .sending)
    }

    @Test("Resetting returns to idle")
    func reset() {
        var progress = OrderProgress()
        progress.begin()
        progress.associate(1)
        progress.apply(id: 1, phase: .settled)
        progress.reset()
        #expect(progress.isIdle)
        #expect(progress.outcome == nil)
    }

    /// Expiry is terminal too: an order past its deadline block is not coming back, and
    /// leaving it busy is the spinner that never ends.
    @Test("Expiry is terminal", arguments: [
        OrderPhase.expired,
        OrderPhase.settled,
        OrderPhase.rejected(code: 1, subReason: nil),
    ])
    func terminalPhases(phase: OrderPhase) {
        var progress = OrderProgress()
        progress.begin()
        progress.associate(1)
        progress.apply(id: 1, phase: phase)
        #expect(progress.outcome?.isTerminal == true)
    }
}
