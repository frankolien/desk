import Foundation

/// The window in which the trading key exists.
///
/// The product claim is that the key does not exist at rest: a Face ID touch derives it
/// and it lives only in memory. That claim is only true if this is the sole owner. Nothing
/// is handed a key here — callers borrow one for the duration of a closure, so there is
/// no second reference to outlive a lock and no way for a component to keep signing after
/// the key is gone.
///
/// **There is no timer while Desk is open.** The first version expired the key after
/// fifteen minutes, and the app then signed the person out — including in the middle of
/// closing a losing position, which is the one moment an app must never stand between a
/// person and their decision. The trading key cannot move money: deposits and withdrawals
/// are signed by the wallet key, with Face ID every time. Stolen, its worst case is trades
/// on the account, not theft of it. A countdown on that key was friction with no security
/// behind it.
///
/// What does end it:
///   - Desk staying in the background past `backgroundGrace`.
///   - The phone locking, or the person locking Desk — both `end()`.
///
/// An optional absolute `lifetime` remains for callers that want one. Desk sets none.
public actor SigningSession {
    public enum Failure: Error, Sendable, Equatable {
        case closed
    }

    /// How long Desk may sit in the background before the key is wiped.
    ///
    /// Five minutes. It was twenty seconds, set by iOS's background execution limit so the
    /// wipe could run before suspension; now the check runs on return instead, against a
    /// monotonic clock, so the window can be the one a person would choose. Answering a
    /// message or checking a price elsewhere costs nothing on return; a phone left on a
    /// table for the afternoon asks for Face ID again. And since the key is also sealed
    /// in the keychain (`TradingKeyVault`), that Face ID is one prompt, not a passkey.
    public static let backgroundGrace: Duration = .seconds(300)

    private let lifetime: Duration?
    private let grace: Duration
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
        self.grace = backgroundGrace
        self.now = now
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

    /// Time left before a configured ceiling. Nil when there is no ceiling — Desk
    /// configures none — and nil when closed.
    public var remaining: Duration? {
        expireIfDue()
        guard key != nil, let deadline else { return nil }
        return now().duration(to: deadline)
    }

    /// Lends the key for one operation. It must not escape `body` — the whole property
    /// this type provides is that it does not.
    public func withTradingKey<T: Sendable>(_ body: @Sendable (TradingKey) throws -> T) throws -> T {
        expireIfDue()
        guard let key else { throw Failure.closed }
        return try body(key)
    }

    /// Pushes a configured ceiling out. Only meaningful while open and only when a ceiling
    /// exists: a closed session is reopened with Face ID, never extended.
    public func extend() {
        expireIfDue()
        guard key != nil, let lifetime else { return }
        deadline = now().advanced(by: lifetime)
    }

    /// Wipes the key. Used for the phone locking, for the person locking Desk, and for
    /// signing out.
    public func end() {
        key = nil
        deadline = nil
        backgroundedAt = nil
    }

    /// Desk left the foreground. The key survives the grace period and no longer.
    ///
    /// Only the first event starts the clock. iOS can report the transition more than
    /// once, and restarting the grace on each report would let a key outlive it.
    public func enterBackground() {
        guard key != nil, backgroundedAt == nil else { return }
        backgroundedAt = now()
    }

    /// Desk is back in the foreground.
    ///
    /// The absence is checked before it is forgotten. If iOS suspended Desk before the
    /// background wipe could run, the key is still in memory at this point — and it is
    /// wiped here, before anything can borrow it.
    public func enterForeground() {
        expireIfDue()
        backgroundedAt = nil
    }

    /// Applies whichever expiry is due now. Called at the end of the background grace.
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
