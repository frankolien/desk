import DeskAuth
import Foundation

@MainActor
protocol PasskeyService: Sendable {
    var lastSeenAddress: EthereumAddress? { get }

    /// Never creates a passkey (that is `createAccounts()`): one created by accident is a
    /// different wallet, and the funded one becomes unreachable.
    func deriveAccounts(tradingIndex: @Sendable (EthereumAddress) -> UInt32) async throws -> DerivedAccounts

    func createAccounts(tradingIndex: @Sendable (EthereumAddress) -> UInt32) async throws -> DerivedAccounts

    /// Scoped rather than returned: the secp256k1 key can move collateral, so nothing may hold it.
    func withKeys<T: Sendable>(
        _ body: @Sendable (WalletKey, TradingKeys) async throws -> T
    ) async throws -> T
}

/// Indexes 0 and 1 were enrolled by early builds whose tokens were lost, so enrolment
/// starts here and moves on only if Perpl says a key is already registered.
enum TradingKeyIndex {
    static let initial: UInt32 = 2
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
