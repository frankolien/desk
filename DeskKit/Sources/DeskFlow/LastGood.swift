import DeskPerpl
import Foundation

/// A value that survives a bad network.
///
/// The product's fourth principle: a failed poll shows the last good figure with a note
/// on its age, never a zero and never an empty screen. A trading app that shows a zero
/// position during a reconnect is a trading app that causes a panic sell, so the type
/// makes that impossible — `recordFailure` cannot reach the value, and there is no way
/// to clear one except by replacing it with a better one.
public struct LastGood<Value: Sendable>: Sendable {
    public private(set) var observation: Observed<Value>?
    /// Reset by any success. Drives the backoff and decides when a problem is worth
    /// saying out loud.
    public private(set) var consecutiveFailures = 0
    /// The last thing that went wrong, kept for the sentence on screen. Never a reason
    /// to hide the value it failed to replace.
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

    /// Deliberately cannot touch `observation`. That is the whole type.
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

/// How long to wait before trying again, and when to admit to the user that we are.
///
/// Retry is silent at first and becomes visible only once it has failed enough to be
/// worth a sentence. A spinner over a number that is still correct is worse than no
/// spinner at all.
public struct Backoff: Sendable, Hashable {
    public let base: Duration
    public let cap: Duration
    /// Below this many consecutive failures nothing is said on screen. One dropped frame
    /// on a train is not news.
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

    /// Doubling, capped. No jitter: jitter exists to stop a fleet of clients retrying in
    /// lockstep, and one phone reconnecting stampedes nothing — so it would only make
    /// the behaviour untestable.
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

    /// Whether the screen should say something is wrong, as opposed to quietly showing a
    /// slightly older number.
    public func shouldReportProblem(_ backoff: Backoff = .default) -> Bool {
        backoff.isWorthMentioning(afterFailures: consecutiveFailures)
    }
}
