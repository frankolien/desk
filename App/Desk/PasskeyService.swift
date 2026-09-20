import DeskAuth
import Foundation

@MainActor
protocol PasskeyService: Sendable {
    var lastSeenAddress: EthereumAddress? { get }

    /// Signs in with an existing passkey. Never creates one — creating is
    /// `createAccounts()`, and the separation is load-bearing: a passkey created by
    /// accident is a different wallet, and the funded one becomes unreachable.
    /// `tradingIndex` is asked once the address is known, because which trading key a
    /// wallet uses is recorded against that address.
    func deriveAccounts(tradingIndex: @Sendable (EthereumAddress) -> UInt32) async throws -> DerivedAccounts

    /// Creates a passkey and the wallet derived from it. Only ever from an explicit
    /// choice by the user.
    func createAccounts(tradingIndex: @Sendable (EthereumAddress) -> UInt32) async throws -> DerivedAccounts

    /// Borrows both keys for exactly one piece of work.
    ///
    /// Scoped rather than returned, because the secp256k1 key is the one that can move
    /// collateral and nothing may hold it. Both come from a single ceremony, so opening a
    /// desk is one Face ID prompt rather than four — and the trading key is passed
    /// alongside rather than taken out of `SigningSession`, which deliberately has no way
    /// to hand its key out.
    ///
    /// A fresh ceremony per call is the right trade here: this key signs approvals,
    /// deposits and withdrawals, which happen a handful of times in the life of an
    /// account and are exactly where a prompt feels earned.
    func withKeys<T: Sendable>(
        _ body: @Sendable (WalletKey, TradingKeys) async throws -> T
    ) async throws -> T
}

/// Which derived trading key a new desk tries first. Indexes 0 and 1 were enrolled by
/// early builds whose tokens were lost, so every wallet starts here and moves on only if
/// Perpl says a key is already registered.
enum TradingKeyIndex {
    static let initial: UInt32 = 2
    /// How far enrolment walks before giving up; each step is one refused request.
    static let attempts: UInt32 = 8
}

struct TradingKeys: Sendable {
    fileprivate let source: PRFSource

    func key(at index: UInt32) throws -> TradingKey {
        try PasskeyAccounts.deriveTradingKey(prfOutput: try source.bytes(), index: index)
    }
}

final class PRFSource: @unchecked Sendable {
    private let lock = NSLock()
    private var output: Data?

    init(_ output: Data) { self.output = output }

    func bytes() throws -> Data {
        try lock.withLock {
            guard let output else { throw PasskeyFailure.prfReturnedNothing }
            return output
        }
    }

    func wipe() {
        lock.withLock {
            let count = output?.count ?? 0
            output?.resetBytes(in: 0..<count)
            output = nil
        }
    }
}

extension TradingKeys {
    /// Runs `body` with keys from `prf`, then wipes the bytes whatever happens.
    static func scoped<T: Sendable>(
        prf: Data, _ body: @Sendable (TradingKeys) async throws -> T
    ) async rethrows -> T {
        let source = PRFSource(prf)
        defer { source.wipe() }
        return try await body(TradingKeys(source: source))
    }
}

struct DerivedAccounts: Sendable {
    let address: EthereumAddress
    let trading: TradingKey
    let hasDesk: Bool
}

#if DEBUG
/// A fixed PRF output, so the screens run without hardware. Compiled out of release on purpose:
/// shipped, it would hand every user the same wallet.
struct StubPasskeyService: PasskeyService {
    /// Remembered like the real ceremony remembers, so the simulator takes the returning
    /// path — Face ID under the mark, no onboarding — once it has signed in once.
    private static let seenKey = "desk.stub.lastSeen"

    var lastSeenAddress: EthereumAddress? {
        guard UserDefaults.standard.bool(forKey: Self.seenKey) else { return nil }
        return try? PasskeyAccounts.deriveAddress(prfOutput: Data(repeating: 0x2A, count: 32))
    }

    func deriveAccounts(tradingIndex: @Sendable (EthereumAddress) -> UInt32) async throws -> DerivedAccounts {
        try await Task.sleep(for: .milliseconds(600))
        let pretendPRF = Data(repeating: 0x2A, count: 32)
        let address = try PasskeyAccounts.deriveAddress(prfOutput: pretendPRF)
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        return DerivedAccounts(
            address: address,
            trading: try PasskeyAccounts.deriveTradingKey(
                prfOutput: pretendPRF, index: tradingIndex(address)),
            hasDesk: false)
    }

    func createAccounts(tradingIndex: @Sendable (EthereumAddress) -> UInt32) async throws -> DerivedAccounts {
        try await deriveAccounts(tradingIndex: tradingIndex)
    }

    func withKeys<T: Sendable>(
        _ body: @Sendable (WalletKey, TradingKeys) async throws -> T
    ) async throws -> T {
        var prf = Data(repeating: 0x2A, count: 32)
        defer { prf.resetBytes(in: 0..<prf.count) }
        let wallet = try PasskeyAccounts.deriveWalletKey(prfOutput: prf)
        return try await TradingKeys.scoped(prf: prf) { try await body(wallet, $0) }
    }
}
#endif

/// What a release build gets until the real ceremony exists. It fails with the sentence
/// the user should read rather than silently deriving something.
struct UnavailablePasskeyService: PasskeyService {
    var lastSeenAddress: EthereumAddress? { nil }

    func deriveAccounts(tradingIndex: @Sendable (EthereumAddress) -> UInt32) async throws -> DerivedAccounts {
        throw PasskeyFailure.relyingPartyNotAssociated(try RelyingParty("desk.invalid"))
    }

    func createAccounts(tradingIndex: @Sendable (EthereumAddress) -> UInt32) async throws -> DerivedAccounts {
        throw PasskeyFailure.relyingPartyNotAssociated(try RelyingParty("desk.invalid"))
    }

    func withKeys<T: Sendable>(
        _ body: @Sendable (WalletKey, TradingKeys) async throws -> T
    ) async throws -> T {
        throw PasskeyFailure.relyingPartyNotAssociated(try RelyingParty("desk.invalid"))
    }
}
