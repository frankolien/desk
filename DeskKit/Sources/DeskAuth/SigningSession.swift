import Foundation

/// The window in which the trading key exists.
///
/// The product claim is that the key does not exist at rest: a Face ID touch derives it,
/// it lives in memory for the session, and it is gone when the session ends or the app
/// leaves the foreground. That claim is only true if this is the sole owner. Nothing is
/// handed a key here — callers borrow one for the duration of a closure, so there is no
/// second reference to outlive the session and no way for a component to keep signing
/// after the user ended it.
public actor SigningSession {
    public enum Failure: Error, Sendable, Equatable {
        case closed
    }

    /// Fifteen minutes, as the Account screen says.
    public static let defaultLifetime: Duration = .seconds(900)

    private let lifetime: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private var key: TradingKey?
    private var deadline: ContinuousClock.Instant?

    /// The deadline is monotonic on purpose. A wall clock can be wound backwards from
    /// Settings, and a session that could be extended that way is not a session.
    public init(
        lifetime: Duration = SigningSession.defaultLifetime,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.lifetime = lifetime
        self.now = now
    }

    public func open(_ key: TradingKey) {
        self.key = key
        deadline = now().advanced(by: lifetime)
    }

    public var isOpen: Bool {
        expireIfDue()
        return key != nil
    }

    /// What the countdown on the Account screen renders. Nil when closed.
    public var remaining: Duration? {
        expireIfDue()
        guard let deadline else { return nil }
        return now().duration(to: deadline)
    }

    /// Lends the key for one operation. It must not escape `body` — the whole property
    /// this type provides is that it does not.
    public func withTradingKey<T: Sendable>(_ body: @Sendable (TradingKey) throws -> T) throws -> T {
        expireIfDue()
        guard let key else { throw Failure.closed }
        return try body(key)
    }

    /// Pushes the deadline out. Only meaningful while open: an expired session is
    /// reopened with Face ID, never extended.
    public func extend() {
        expireIfDue()
        guard key != nil else { return }
        deadline = now().advanced(by: lifetime)
    }

    public func end() {
        key = nil
        deadline = nil
    }

    /// The app leaving the foreground ends the session outright. This is the line the
    /// Account screen's promise rests on, so it is not a shortened timer.
    public func enterBackground() { end() }

    private func expireIfDue() {
        guard let deadline, now() >= deadline else { return }
        end()
    }
}
