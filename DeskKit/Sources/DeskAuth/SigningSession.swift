import Foundation

/// The key is lent for one closure and never handed out, so nothing can keep signing after a lock.
public actor SigningSession {
    public enum Failure: Error, Sendable, Equatable {
        case closed
    }

    public static let backgroundGrace: Duration = .seconds(300)
    /// While copying, the key stays alive for the copy loop only; returning after the ordinary grace
    /// still asks for Face ID before the screens show.
    public static let awayGrace: Duration = .seconds(12 * 3600)

    private let lifetime: Duration?
    private let baseGrace: Duration
    private var grace: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private var key: TradingKey?
    private var deadline: ContinuousClock.Instant?
    private var backgroundedAt: ContinuousClock.Instant?

    /// Every instant is monotonic on purpose. A wall clock can be wound backwards from
    /// Settings, and a key that could be kept alive that way is not being wiped.
    public init(
        lifetime: Duration? = nil,
        backgroundGrace: Duration = SigningSession.backgroundGrace,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.lifetime = lifetime
        self.baseGrace = backgroundGrace
        self.grace = backgroundGrace
        self.now = now
    }

    public func allowAway(_ enabled: Bool) {
        grace = enabled ? Self.awayGrace : baseGrace
    }

    public var absence: Duration? {
        backgroundedAt.map { $0.duration(to: now()) }
    }

    public func open(_ key: TradingKey) {
        self.key = key
        deadline = lifetime.map { now().advanced(by: $0) }
        backgroundedAt = nil
    }

    public var isOpen: Bool {
        expireIfDue()
        return key != nil
    }

    public var remaining: Duration? {
        expireIfDue()
        guard key != nil, let deadline else { return nil }
        return now().duration(to: deadline)
    }

    public func withTradingKey<T: Sendable>(_ body: @Sendable (TradingKey) throws -> T) throws -> T {
        expireIfDue()
        guard let key else { throw Failure.closed }
        return try body(key)
    }

    public func extend() {
        expireIfDue()
        guard key != nil, let lifetime else { return }
        deadline = now().advanced(by: lifetime)
    }

    public func end() {
        key = nil
        deadline = nil
        backgroundedAt = nil
    }

    /// Only the first event starts the clock: iOS can report the transition more than once.
    public func enterBackground() {
        guard key != nil, backgroundedAt == nil else { return }
        backgroundedAt = now()
    }

    /// Checked before the absence is forgotten: if iOS suspended Desk before the background wipe ran,
    /// the key is still in memory here and is wiped before anything can borrow it.
    public func enterForeground() {
        expireIfDue()
        backgroundedAt = nil
    }

    public func expireIfOverdue() {
        expireIfDue()
    }

    private func expireIfDue() {
        let instant = now()
        if let deadline, instant >= deadline {
            end()
        } else if let backgroundedAt, backgroundedAt.duration(to: instant) >= grace {
            end()
        }
    }
}
