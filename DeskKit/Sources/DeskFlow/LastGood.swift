import DeskPerpl
import Foundation

/// A failed poll shows the last good figure with its age, never a zero: a zero position during
/// a reconnect causes a panic sell, so `recordFailure` cannot reach the value.
public struct LastGood<Value: Sendable>: Sendable {
    public private(set) var observation: Observed<Value>?
    public private(set) var consecutiveFailures = 0
    public private(set) var lastFailure: String?

    public init() {}

    public var value: Value? { observation?.value }
    public var hasValue: Bool { observation != nil }

    public mutating func record(
        _ value: Value,
        at instant: ContinuousClock.Instant = ContinuousClock.now,
        serverTimestampMilliseconds: Int64? = nil
    ) {
        observation = Observed(
            value, receivedAt: instant, serverTimestampMilliseconds: serverTimestampMilliseconds)
        consecutiveFailures = 0
        lastFailure = nil
    }

    /// A value from a second source (a live stream beside a polled endpoint). Leaves the polled
    /// source's failures alone, so its backoff keeps growing while it is down.
    public mutating func restamp(_ value: Value, at instant: ContinuousClock.Instant = ContinuousClock.now) {
        observation = Observed(value, receivedAt: instant, serverTimestampMilliseconds: nil)
    }

    public mutating func noteSuccess() {
        consecutiveFailures = 0
        lastFailure = nil
    }

    public mutating func recordFailure(_ reason: String) {
        consecutiveFailures += 1
        lastFailure = reason
    }

    public func age(at instant: ContinuousClock.Instant = ContinuousClock.now) -> Duration? {
        observation?.age(at: instant)
    }

    public func freshness(
        at instant: ContinuousClock.Instant = ContinuousClock.now,
        socketIsConnected: Bool = true,
        policy: FreshnessPolicy = .default
    ) -> Freshness {
        guard let observation else { return .disconnected }
        return policy.state(of: observation, at: instant, socketIsConnected: socketIsConnected)
    }
}

public struct Backoff: Sendable, Hashable {
    public let base: Duration
    public let cap: Duration
    public let visibleAfterFailures: Int

    public init(
        base: Duration = .milliseconds(500),
        cap: Duration = .seconds(30),
        visibleAfterFailures: Int = 3
    ) {
        self.base = base
        self.cap = cap
        self.visibleAfterFailures = visibleAfterFailures
    }

    public static let `default` = Backoff()

    /// Doubling, capped. No jitter: one phone reconnecting stampedes nothing.
    public func delay(afterFailures failures: Int) -> Duration {
        guard failures > 0 else { return .zero }
        var delay = base
        for _ in 1..<min(failures, 32) {
            delay = delay * 2
            if delay >= cap { return cap }
        }
        return min(delay, cap)
    }

    public func isWorthMentioning(afterFailures failures: Int) -> Bool {
        failures >= visibleAfterFailures
    }
}

extension LastGood {
    public func retryDelay(_ backoff: Backoff = .default) -> Duration {
        backoff.delay(afterFailures: consecutiveFailures)
    }

    public func shouldReportProblem(_ backoff: Backoff = .default) -> Bool {
        backoff.isWorthMentioning(afterFailures: consecutiveFailures)
    }
}
