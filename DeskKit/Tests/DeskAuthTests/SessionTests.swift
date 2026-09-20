import Foundation
import Testing

@testable import DeskAuth

/// A clock the test moves by hand.
private final class Ticker: @unchecked Sendable {
    private let lock = NSLock()
    private let base = ContinuousClock.now
    private var offset: Duration = .zero

    func advance(_ amount: Duration) { lock.withLock { offset += amount } }
    func rewind(_ amount: Duration) { lock.withLock { offset -= amount } }
    var instant: ContinuousClock.Instant { lock.withLock { base.advanced(by: offset) } }
}

private func tradingKey() throws -> TradingKey {
    try TradingKey(seed: SecureBytes(Data(repeating: 5, count: 32)))
}

@Suite("The signing session")
struct SigningSessionTests {
    @Test("A closed session has nothing to lend")
    func startsClosed() async throws {
        let session = SigningSession()
        #expect(await session.isOpen == false)
        #expect(await session.remaining == nil)
        await #expect(throws: SigningSession.Failure.closed) {
            try await session.withTradingKey { $0.publicKey }
        }
    }

    /// The change this suite exists to hold. A fifteen-minute window used to sign a person
    /// out mid-trade — including between them and closing a losing position.
    @Test("An open session does not count down while Desk is open")
    func noTimerInForeground() async throws {
        let ticker = Ticker()
        let session = SigningSession(now: { ticker.instant })
        try await session.open(tradingKey())
        ticker.advance(.seconds(60 * 60 * 24))

        #expect(await session.isOpen)
        #expect(await session.remaining == nil)
        #expect(try await session.withTradingKey { $0.publicKey.count } == 32)
    }

    @Test("A configured ceiling still counts down")
    func ceilingCountsDown() async throws {
        let ticker = Ticker()
        let session = SigningSession(lifetime: .seconds(900), now: { ticker.instant })
        try await session.open(tradingKey())

        #expect(await session.remaining == .seconds(900))
        ticker.advance(.seconds(300))
        #expect(await session.remaining == .seconds(600))
        #expect(try await session.withTradingKey { $0.publicKey.count } == 32)
    }

    @Test("The key is gone the moment a configured ceiling passes")
    func ceilingExpires() async throws {
        let ticker = Ticker()
        let session = SigningSession(lifetime: .seconds(900), now: { ticker.instant })
        try await session.open(tradingKey())
        ticker.advance(.seconds(900))

        #expect(await session.isOpen == false)
        #expect(await session.remaining == nil)
        await #expect(throws: SigningSession.Failure.closed) {
            try await session.withTradingKey { $0.publicKey }
        }
    }

    @Test("Winding the clock backwards does not extend a session")
    func monotonic() async throws {
        // A wall clock can be moved from Settings. A session that could be extended that
        // way is not a session, which is why every instant is monotonic.
        let ticker = Ticker()
        let session = SigningSession(lifetime: .seconds(60), now: { ticker.instant })
        try await session.open(tradingKey())
        ticker.advance(.seconds(60))
        #expect(await session.isOpen == false)
        ticker.rewind(.seconds(3600))
        #expect(await session.isOpen == false)
    }

    @Test("An expired session is reopened, never extended")
    func extendOnlyWhileOpen() async throws {
        let ticker = Ticker()
        let session = SigningSession(lifetime: .seconds(60), now: { ticker.instant })
        try await session.open(tradingKey())
        ticker.advance(.seconds(30))
        await session.extend()
        #expect(await session.remaining == .seconds(60))

        ticker.advance(.seconds(60))
        await session.extend()
        #expect(await session.isOpen == false)
    }

    @Test("A short trip to another app keeps the key")
    func shortAbsence() async throws {
        let ticker = Ticker()
        let session = SigningSession(backgroundGrace: .seconds(20), now: { ticker.instant })
        try await session.open(tradingKey())

        await session.enterBackground()
        ticker.advance(.seconds(19))
        #expect(await session.isOpen)

        await session.enterForeground()
        ticker.advance(.seconds(3600))
        #expect(await session.isOpen, "a return inside the grace clears the absence entirely")
    }

    @Test("Staying away past the grace wipes the key")
    func longAbsence() async throws {
        let ticker = Ticker()
        let session = SigningSession(backgroundGrace: .seconds(20), now: { ticker.instant })
        try await session.open(tradingKey())

        await session.enterBackground()
        ticker.advance(.seconds(20))
        await session.expireIfOverdue()

        #expect(await session.isOpen == false)
        await #expect(throws: SigningSession.Failure.closed) {
            try await session.withTradingKey { $0.publicKey }
        }
    }

    /// The background task failing: iOS suspended Desk before the wipe ran, so nothing
    /// wiped the key while it was away. It must still be unusable on the way back in.
    @Test("Coming back after the grace finds the key gone even if nothing wiped it")
    func returnAfterGrace() async throws {
        let ticker = Ticker()
        let session = SigningSession(backgroundGrace: .seconds(20), now: { ticker.instant })
        try await session.open(tradingKey())

        await session.enterBackground()
        ticker.advance(.seconds(45))
        await session.enterForeground()

        #expect(await session.isOpen == false)
    }

    /// iOS can report the transition to the background more than once. Restarting the
    /// clock on each report would let the key outlive the grace.
    @Test("A second background event does not restart the grace")
    func graceStartsOnce() async throws {
        let ticker = Ticker()
        let session = SigningSession(backgroundGrace: .seconds(20), now: { ticker.instant })
        try await session.open(tradingKey())

        await session.enterBackground()
        ticker.advance(.seconds(15))
        await session.enterBackground()
        ticker.advance(.seconds(6))

        #expect(await session.isOpen == false)
    }

    @Test("Opening again forgets an earlier absence")
    func reopenClearsAbsence() async throws {
        let ticker = Ticker()
        let session = SigningSession(backgroundGrace: .seconds(20), now: { ticker.instant })
        try await session.open(tradingKey())

        await session.enterBackground()
        ticker.advance(.seconds(10))
        try await session.open(tradingKey())
        ticker.advance(.seconds(15))

        #expect(await session.isOpen)
    }

    @Test("Locking ends it outright")
    func locking() async throws {
        let session = SigningSession()
        try await session.open(tradingKey())
        await session.end()
        #expect(await session.isOpen == false)
        await #expect(throws: SigningSession.Failure.closed) {
            try await session.withTradingKey { $0.publicKey }
        }
    }

    /// The grace used to have to fit iOS's thirty-second background window, because the
    /// wipe was scheduled inside it. It no longer is: the absence is measured on return
    /// against a monotonic clock, so the grace can be the one a person would choose, and
    /// the test above this one is what guarantees a late return still finds the key gone.
    @Test("The grace is long enough that a trip to another app costs nothing")
    func graceIsHuman() {
        #expect(SigningSession.backgroundGrace >= .seconds(60))
    }

    @Test("Ending twice is not an error")
    func endIsIdempotent() async throws {
        let session = SigningSession()
        try await session.open(tradingKey())
        await session.end()
        await session.end()
        #expect(await session.isOpen == false)
    }
}

@Suite("The address guard")
struct AddressGuardTests {
    private let first = EthereumAddress(bytes: Data(repeating: 0xa1, count: 20))!
    private let second = EthereumAddress(bytes: Data(repeating: 0xb2, count: 20))!

    @Test("A first run adopts what it derived")
    func firstRun() {
        #expect(AddressGuard.check(derived: first, against: nil) == .firstRun(first))
        #expect(AddressGuard.check(derived: first, against: nil).mayShowBalance)
    }

    @Test("The same address is the ordinary case")
    func matches() {
        #expect(AddressGuard.check(derived: first, against: first) == .matches(first))
        #expect(AddressGuard.check(derived: first, against: first).mayShowBalance)
    }

    @Test("A changed address never shows a balance")
    func differs() {
        // Apple's synced-passkey bug derives a different address on a second device.
        // Rendering that account's zero balance would read as theft.
        let verdict = AddressGuard.check(derived: second, against: first)
        #expect(verdict == .differs(stored: first, derived: second))
        #expect(verdict.mayShowBalance == false)
    }
}
