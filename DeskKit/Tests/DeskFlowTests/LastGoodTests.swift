import DeskMoney
import DeskPerpl
import Foundation
import Testing

@testable import DeskFlow

@Suite("Never blank")
struct LastGoodTests {
    @Test("Before anything arrives there is nothing, and it says so")
    func empty() {
        let held = LastGood<Money>()
        #expect(held.value == nil)
        #expect(held.hasValue == false)
        #expect(held.age() == nil)
        // Nothing to show is disconnected, not live-with-a-zero.
        #expect(held.freshness() == .disconnected)
    }

    @Test("A failure cannot reach the value it failed to replace")
    func failureKeepsValue() {
        // A trading app that shows a zero position during a reconnect is a trading app
        // that causes a panic sell.
        var held = LastGood<Money>()
        held.record(Money(text: "1250.50")!)
        for index in 1...20 {
            held.recordFailure("socket closed")
            #expect(held.value?.text == "1250.500000", "after \(index) failures")
        }
        #expect(held.consecutiveFailures == 20)
        #expect(held.lastFailure == "socket closed")
    }

    @Test("A success clears the failure count and the reason")
    func successResets() {
        var held = LastGood<Money>()
        held.record(Money(text: "10")!)
        held.recordFailure("timeout")
        held.recordFailure("timeout")
        #expect(held.consecutiveFailures == 2)
        held.record(Money(text: "11")!)
        #expect(held.consecutiveFailures == 0)
        #expect(held.lastFailure == nil)
        #expect(held.value?.text == "11.000000")
    }

    @Test("A failure does not make the value look fresher than it is")
    func ageKeepsGrowing() {
        let base = ContinuousClock.now
        var held = LastGood<Money>()
        held.record(Money(text: "10")!, at: base)
        held.recordFailure("timeout")
        #expect(held.age(at: base.advanced(by: .seconds(9))) == .seconds(9))
        #expect(held.freshness(at: base.advanced(by: .seconds(9))) == .stale)
        #expect(held.freshness(at: base.advanced(by: .seconds(20))) == .disconnected)
    }

    @Test("A closed socket is disconnected even with a value a moment old")
    func closedSocket() {
        let base = ContinuousClock.now
        var held = LastGood<Money>()
        held.record(Money(text: "10")!, at: base)
        #expect(held.freshness(at: base, socketIsConnected: false) == .disconnected)
        // And the value is still there to render, dimmed.
        #expect(held.value != nil)
    }

    @Test("The server's own timestamp is carried but never used for the age")
    func serverTimestampIsForDisplayOnly() {
        let base = ContinuousClock.now
        var held = LastGood<Price>()
        held.record(
            Price(raw: 767_190, decimals: 1)!, at: base,
            serverTimestampMilliseconds: 1_789_295_277_000)
        #expect(held.observation?.serverTimestampMilliseconds == 1_789_295_277_000)
        #expect(held.age(at: base.advanced(by: .seconds(2))) == .seconds(2))
    }
}

@Suite("Backing off")
struct BackoffTests {
    @Test("The first attempt does not wait")
    func noDelayBeforeFailing() {
        #expect(Backoff.default.delay(afterFailures: 0) == .zero)
    }

    @Test("It doubles and then stops doubling")
    func doublesToACap() {
        let backoff = Backoff(base: .milliseconds(500), cap: .seconds(30))
        #expect(backoff.delay(afterFailures: 1) == .milliseconds(500))
        #expect(backoff.delay(afterFailures: 2) == .seconds(1))
        #expect(backoff.delay(afterFailures: 3) == .seconds(2))
        #expect(backoff.delay(afterFailures: 6) == .seconds(16))
        // The seventh doubling would be 32s, so the cap takes over.
        #expect(backoff.delay(afterFailures: 7) == .seconds(30))
        #expect(backoff.delay(afterFailures: 8) == .seconds(30))
        #expect(backoff.delay(afterFailures: 1_000) == .seconds(30))
    }

    @Test("A huge failure count cannot overflow the delay")
    func noOverflow() {
        // `base * 2^n` with an unbounded n is a trap waiting for a long disconnection.
        #expect(Backoff.default.delay(afterFailures: .max) == Backoff.default.cap)
    }

    @Test("Retry is silent until it has failed enough to be worth saying")
    func silentAtFirst() {
        // A spinner over a number that is still correct is worse than no spinner.
        var held = LastGood<Money>()
        held.record(Money(text: "10")!)
        #expect(held.shouldReportProblem() == false)
        held.recordFailure("a")
        #expect(held.shouldReportProblem() == false)
        #expect(held.retryDelay() == .milliseconds(500))
        held.recordFailure("b")
        #expect(held.shouldReportProblem() == false)
        held.recordFailure("c")
        #expect(held.shouldReportProblem())
        #expect(held.retryDelay() == .seconds(2))
    }
}
