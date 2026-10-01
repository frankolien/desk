import Foundation
import Testing

@testable import DeskPerpl

@Suite("Freshness")
struct FreshnessTests {
    private let policy = FreshnessPolicy.default

    @Test("The four states follow the ages on the screen design")
    func thresholds() {
        #expect(policy.state(age: .zero) == .live)
        #expect(policy.state(age: .milliseconds(1_999)) == .live)
        #expect(policy.state(age: .seconds(2)) == .settling)
        #expect(policy.state(age: .milliseconds(4_999)) == .settling)
        #expect(policy.state(age: .seconds(5)) == .stale)
        #expect(policy.state(age: .milliseconds(14_999)) == .stale)
        #expect(policy.state(age: .seconds(15)) == .disconnected)
        #expect(policy.state(age: .seconds(600)) == .disconnected)
    }

    @Test("A connected but stalled socket still goes stale")
    func connectedButStalled() {
        #expect(policy.state(age: .seconds(8), socketIsConnected: true) == .stale)
    }

    @Test("A closed socket is disconnected at once, whatever the age says")
    func closedSocketIsImmediate() {
        #expect(policy.state(age: .zero, socketIsConnected: false) == .disconnected)
        #expect(policy.state(age: .milliseconds(100), socketIsConnected: false) == .disconnected)
    }

    @Test("Only disconnection stops a trade")
    func confirmRules() {
        #expect(Freshness.live.allowsConfirm)
        #expect(Freshness.settling.allowsConfirm)
        #expect(Freshness.stale.allowsConfirm)
        #expect(Freshness.disconnected.allowsConfirm == false)
    }

    @Test("Every state still renders the last known value")
    func neverBlank() {
        for state in Freshness.allCases { #expect(state.showsLastKnownValue) }
        #expect(Freshness.live.flashesOnChange)
        #expect(Freshness.settling.flashesOnChange == false)
        #expect(Freshness.stale.freezesDigits)
    }

    @Test("Age is measured locally, so a wrong device clock cannot fake it")
    func ageIsLocal() {
        // A device five minutes out would otherwise show every live price as long stale.
        let base = ContinuousClock.now
        let observation = Observed(
            772_281, receivedAt: base,
            serverTimestampMilliseconds: 1_789_295_277_000)
        #expect(policy.state(of: observation, at: base.advanced(by: .seconds(1))) == .live)
        #expect(policy.state(of: observation, at: base.advanced(by: .seconds(7))) == .stale)
        #expect(observation.age(at: base.advanced(by: .seconds(3))) == .seconds(3))
        // The server's own timestamp is carried but never used for the age.
        #expect(observation.serverTimestampMilliseconds == 1_789_295_277_000)
    }
}
