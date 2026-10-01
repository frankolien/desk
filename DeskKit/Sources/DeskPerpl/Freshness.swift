import Foundation

/// Age is measured on a local monotonic clock, never the server's timestamp, so a device
/// whose wall clock is off can't show a stale price as live.
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

public enum Freshness: String, Sendable, Hashable, CaseIterable {
    case live
    case settling
    case stale
    case disconnected

    /// Only the last of these stops a trade; a stale price is re-priced on submit, since a
    /// quiet market is normal.
    public var allowsConfirm: Bool { self != .disconnected }

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
