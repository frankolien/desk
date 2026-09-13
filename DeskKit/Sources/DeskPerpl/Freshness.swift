import Foundation

/// A value and when *we* received it.
///
/// The age is measured against a local monotonic clock, never against the server's
/// timestamp. A device whose wall clock is five minutes out would otherwise show every
/// live price as long stale, and a device set five minutes early would show a stale one
/// as live. The server timestamp is carried alongside for display and correlation only.
public struct Observed<Value: Sendable>: Sendable {
    public let value: Value
    public let receivedAt: ContinuousClock.Instant
    public let serverTimestampMilliseconds: Int64?

    public init(
        _ value: Value,
        receivedAt: ContinuousClock.Instant = ContinuousClock.now,
        serverTimestampMilliseconds: Int64? = nil
    ) {
        self.value = value
        self.receivedAt = receivedAt
        self.serverTimestampMilliseconds = serverTimestampMilliseconds
    }

    public func age(at instant: ContinuousClock.Instant = ContinuousClock.now) -> Duration {
        receivedAt.duration(to: instant)
    }
}

/// How much a number on screen can be trusted.
///
/// A mark price is not a ten-hertz stream: Perpl writes mark on chain only when it moves
/// more than 0.05%, so quiet is normal and quiet is not the same as broken. The states
/// exist because a socket can be connected and stalled, and a trading app that shows a
/// stale number as a live one is lying.
public enum Freshness: String, Sendable, Hashable, CaseIterable {
    case live
    case settling
    case stale
    case disconnected

    /// Only the last of these stops a trade. A stale price is re-priced on submit rather
    /// than blocking the user, because refusing to trade on a quiet market would be the
    /// wrong call far more often than the right one.
    public var allowsConfirm: Bool { self != .disconnected }

    /// Never blank, never a dash, never a zero, never a spinner over a number. Even
    /// disconnected renders the last known good value, dimmed.
    public var showsLastKnownValue: Bool { true }

    public var freezesDigits: Bool { self == .stale || self == .disconnected }

    public var flashesOnChange: Bool { self == .live }
}

public struct FreshnessPolicy: Sendable, Hashable {
    public let settlingAfter: Duration
    public let staleAfter: Duration
    public let disconnectedAfter: Duration

    public init(
        settlingAfter: Duration = .seconds(2),
        staleAfter: Duration = .seconds(5),
        disconnectedAfter: Duration = .seconds(15)
    ) {
        self.settlingAfter = settlingAfter
        self.staleAfter = staleAfter
        self.disconnectedAfter = disconnectedAfter
    }

    public static let `default` = FreshnessPolicy()

    /// A closed socket is disconnected at once, whatever the age says. Waiting fifteen
    /// seconds to admit something we already know would leave the confirm button live
    /// over a price that cannot be refreshed.
    public func state(age: Duration, socketIsConnected: Bool = true) -> Freshness {
        guard socketIsConnected else { return .disconnected }
        if age >= disconnectedAfter { return .disconnected }
        if age >= staleAfter { return .stale }
        if age >= settlingAfter { return .settling }
        return .live
    }

    public func state<Value>(
        of observation: Observed<Value>,
        at instant: ContinuousClock.Instant = ContinuousClock.now,
        socketIsConnected: Bool = true
    ) -> Freshness {
        state(age: observation.age(at: instant), socketIsConnected: socketIsConnected)
    }
}
