import AuthenticationServices
import CryptoKit
import DeskAuth
import Foundation
import UIKit

@MainActor
final class PasskeyCeremony: NSObject, PasskeyService {
    /// 18.4 is the first version whose PRF output can be trusted. Below it the ceremony
    /// refuses rather than deriving an address that will not reproduce.
    static let minimumSystemVersion = OperatingSystemVersion(majorVersion: 18, minorVersion: 4, patchVersion: 0)

    private let relyingParty: RelyingParty
    private let displayName: String
    private let store: LastSeenAddressStore

    init(relyingParty: RelyingParty, displayName: String = "Desk", store: LastSeenAddressStore = .standard) {
        self.relyingParty = relyingParty
        self.displayName = displayName
        self.store = store
    }

    var lastSeenAddress: EthereumAddress? { store.address }

    /// Signs in with an existing passkey and never creates one: falling through to
    /// registration on a cancel would mint a second wallet at a different address.
    func deriveAccounts(tradingIndex: @Sendable (EthereumAddress) -> UInt32) async throws -> DerivedAccounts {
        try requireSupportedSystem()
        return try await derive(from: try await assertExisting(), tradingIndex: tradingIndex)
    }

    /// Refuses if this device already derived an address: a second passkey is a second
    /// wallet, and the first one's funds become unreachable from the app.
    func createAccounts(tradingIndex: @Sendable (EthereumAddress) -> UInt32) async throws -> DerivedAccounts {
        try requireSupportedSystem()
        if let existing = store.address {
            throw PasskeyFailure.platformRefused(
                "This device already has a Desk account (\(Self.short(existing))). Creating "
                    + "a second passkey would make a different wallet and leave that one "
                    + "unreachable. Use Face ID to sign in instead.")
        }
        return try await derive(from: try await createNew(), tradingIndex: tradingIndex)
    }

    private func requireSupportedSystem() throws {
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(Self.minimumSystemVersion) else {
            throw PasskeyFailure.prfUnsupported
        }
    }

    private func derive(
        from output: Data, tradingIndex: @Sendable (EthereumAddress) -> UInt32
    ) async throws -> DerivedAccounts {
        var prf = output
        defer { prf.resetBytes(in: 0..<prf.count) }
        guard prf.count == 32 else { throw PasskeyFailure.prfReturnedNothing }

        let address = try PasskeyAccounts.deriveAddress(prfOutput: prf)
        let trading = try PasskeyAccounts.deriveTradingKey(
            prfOutput: prf, index: tradingIndex(address))
        store.record(address)
        return DerivedAccounts(address: address, trading: trading, hasDesk: false)
    }

    static func short(_ address: EthereumAddress) -> String {
        let text = address.checksummed
        return text.prefix(6) + "…" + text.suffix(4)
    }

    func withKeys<T: Sendable>(
        _ body: @Sendable (WalletKey, TradingKeys) async throws -> T
    ) async throws -> T {
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(Self.minimumSystemVersion) else {
            throw PasskeyFailure.prfUnsupported
        }
        var prf = try await assertExisting()
        defer { prf.resetBytes(in: 0..<prf.count) }
        guard prf.count == 32 else { throw PasskeyFailure.prfReturnedNothing }

        let wallet = try PasskeyAccounts.deriveWalletKey(prfOutput: prf)
        return try await TradingKeys.scoped(prf: prf) { try await body(wallet, $0) }
    }

    private func assertExisting() async throws -> Data {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: relyingParty.identifier)
        let request = provider.createCredentialAssertionRequest(challenge: Self.challenge())
        // A static member, not an initialiser: the Swift overlay refines the init away.
        request.prf = .inputValues(
            .init(saltInput1: PasskeyAccounts.prfSalt, saltInput2: nil),
            perCredentialInputValues: nil)
        return try await perform(request, isAssertion: true)
    }

    private func createNew() async throws -> Data {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: relyingParty.identifier)
        let request = provider.createCredentialRegistrationRequest(
            challenge: Self.challenge(),
            name: displayName,
            userID: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
        request.prf = .checkForSupport
        return try await perform(request, isAssertion: false)
    }

    private func perform(_ request: ASAuthorizationRequest, isAssertion: Bool) async throws -> Data {
        let controller = ASAuthorizationController(authorizationRequests: [request])
        let delegate = CeremonyDelegate(isAssertion: isAssertion)
        controller.delegate = delegate
        controller.presentationContextProvider = self

        let authorization = try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            controller.performRequests()
        }

        switch authorization.credential {
        case let assertion as ASAuthorizationPlatformPublicKeyCredentialAssertion:
            guard let key = assertion.prf?.first else { throw PasskeyFailure.prfReturnedNothing }
            return Data(key.withUnsafeBytes { Array($0) })
        case let registration as ASAuthorizationPlatformPublicKeyCredentialRegistration:
            guard registration.prf?.isSupported == true else { throw PasskeyFailure.prfUnsupported }
            // Registration returns no key material, so the key comes from an assertion
            // against the credential just made.
            return try await assertExisting()
        default:
            throw PasskeyFailure.platformRefused("That credential can't be used with Desk.")
        }
    }

    /// Locally random on purpose: there is no server to replay an assertion to, and the
    /// PRF output depends only on the credential and the salt.
    private static func challenge() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    }
}

extension PasskeyCeremony: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow
            ?? scenes.first?.keyWindow
        return window ?? ASPresentationAnchor()
    }
}

private final class CeremonyDelegate: NSObject, ASAuthorizationControllerDelegate {
    var continuation: CheckedContinuation<ASAuthorization, any Error>?
    private let isAssertion: Bool

    init(isAssertion: Bool) { self.isAssertion = isAssertion }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        continuation?.resume(returning: authorization)
        continuation = nil
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: any Error
    ) {
        continuation?.resume(throwing: Self.translate(error, isAssertion: isAssertion))
        continuation = nil
    }

    private static func translate(_ error: any Error, isAssertion: Bool) -> any Error {
        guard let authorization = error as? ASAuthorizationError else {
            let underlying = error as NSError
            return PasskeyFailure.platformRefused(
                "Face ID could not finish (\(underlying.domain) \(underlying.code)).")
        }
        switch authorization.code {
        case .canceled:
            // Also returned when no credential matched; treated as a cancel, never as
            // "create one", which would silently make a second wallet.
            return PasskeyFailure.cancelledByUser
        case .invalidResponse:
            return PasskeyFailure.prfReturnedNothing
        case .failed, .notHandled:
            let lead = isAssertion
                ? "Face ID sign-in needs one more setup step."
                : "Account creation needs one more setup step."
            return PasskeyFailure.platformRefused(
                "\(lead) Enable Associated Domains for Desk in Apple Developer, "
                    + "refresh the signing profile, then rebuild the app.")
        default:
            return PasskeyFailure.platformRefused(
                "Face ID could not finish (code \(authorization.code.rawValue)).")
        }
    }
}

struct LastSeenAddressStore: Sendable {
    static let standard = LastSeenAddressStore(key: "desk.lastSeenAddress")

    let key: String

    var address: EthereumAddress? {
        guard let text = UserDefaults.standard.string(forKey: key) else { return nil }
        return EthereumAddress(bytes: Self.hex(text))
    }

    private static func hex(_ text: String) -> Data {
        let digits = text.hasPrefix("0x") || text.hasPrefix("0X") ? String(text.dropFirst(2)) : text
        guard digits.count == 40 else { return Data() }
        var bytes = Data()
        var index = digits.startIndex
        while let next = digits.index(index, offsetBy: 2, limitedBy: digits.endIndex) {
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return Data() }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    func record(_ address: EthereumAddress) {
        UserDefaults.standard.set(address.checksummed, forKey: key)
    }
}
