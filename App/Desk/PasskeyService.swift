import DeskAuth
import Foundation

/// What the app needs from a passkey ceremony.
///
/// Behind a protocol so every screen can be built and run before the relying party
/// exists — the real implementation needs an associated domain, which needs a paid
/// developer account and a domain that serves an association file without redirecting.
protocol PasskeyService: Sendable {
    var lastSeenAddress: EthereumAddress? { get }
    func deriveAccounts() async throws -> DerivedAccounts
}

struct DerivedAccounts: Sendable {
    let address: EthereumAddress
    let trading: TradingKey
    let hasDesk: Bool
}

#if DEBUG
/// Derives from a fixed seed so the screens can be driven end to end without hardware.
///
/// It performs the real derivation — the same `PasskeyAccounts` path a device will take —
/// and only the PRF output is invented.
///
/// Compiled out of release builds on purpose. A fixed PRF output derives a fixed key, so
/// a shipped build that fell back to this would hand every user the same wallet. The
/// `#if DEBUG` is the only thing standing between a convenience and that, which is why
/// it wraps the type rather than a call site.
struct StubPasskeyService: PasskeyService {
    var lastSeenAddress: EthereumAddress? { nil }

    func deriveAccounts() async throws -> DerivedAccounts {
        try await Task.sleep(for: .milliseconds(600))
        let pretendPRF = Data(repeating: 0x2A, count: 32)
        return DerivedAccounts(
            address: try PasskeyAccounts.deriveAddress(prfOutput: pretendPRF),
            trading: try PasskeyAccounts.deriveTradingKey(prfOutput: pretendPRF),
            hasDesk: false)
    }
}
#endif

/// What a release build gets until the real ceremony exists. It fails with the sentence
/// the user should read rather than silently deriving something.
struct UnavailablePasskeyService: PasskeyService {
    var lastSeenAddress: EthereumAddress? { nil }

    func deriveAccounts() async throws -> DerivedAccounts {
        throw PasskeyFailure.relyingPartyNotAssociated(try RelyingParty("desk.invalid"))
    }
}
