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

    @Test("An open session lends the key and counts down")
    func opensAndCountsDown() async throws {
        let ticker = Ticker()
        let session = SigningSession(lifetime: .seconds(900), now: { ticker.instant })
        try await session.open(tradingKey())

        #expect(await session.isOpen)
        #expect(await session.remaining == .seconds(900))
        ticker.advance(.seconds(300))
        #expect(await session.remaining == .seconds(600))
        #expect(try await session.withTradingKey { $0.publicKey.count } == 32)
    }

    @Test("The key is gone the moment the window closes")
    func expires() async throws {
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
        // way is not a session, which is why the deadline is monotonic.
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

    @Test("Backgrounding ends it outright, not early")
    func backgrounding() async throws {
        let session = SigningSession()
        try await session.open(tradingKey())
        #expect(await session.isOpen)
        await session.enterBackground()
        #expect(await session.isOpen == false)
        await #expect(throws: SigningSession.Failure.closed) {
            try await session.withTradingKey { $0.publicKey }
        }
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
