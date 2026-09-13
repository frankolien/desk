import AuthenticationServices
import CryptoKit
import DeskAuth
import Foundation
import UIKit

/// The real ceremony: a platform passkey, the PRF extension, and nothing kept afterwards.
///
/// This is the whole product in one file. The PRF output *is* the wallet — there is no
/// key in the keychain, no encrypted blob, no export. Face ID produces thirty-two bytes,
/// those bytes derive both accounts, and the bytes are wiped on the next line.
///
/// Three things here are not obvious and all three are load-bearing.
///
/// **iOS 18.4, not 18.0.** PRF has existed on the API since 18.0, but 18.0 through 18.3
/// return *wrong* values — not an error, a different thirty-two bytes. A wrong value is
/// silently a different wallet, so the floor is enforced at run time as well as in the
/// deployment target, because a deployment target is a build setting and this is a
/// correctness boundary.
///
/// **Assert first, create second.** Creating a credential when one already exists makes a
/// second one: Mera generates a fresh user handle on every create, so the new passkey
/// derives a different address and the user's funds appear to vanish. So the flow always
/// tries to use an existing credential and only creates when the platform says there is
/// none.
///
/// **No fallback, ever.** Every failure path throws. There is deliberately no branch that
/// reaches for a stored key on failure, because there is no stored key — and a branch that
/// implied otherwise would be the one bug that loses someone's money.
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

    /// Signs in with an existing passkey. **Never creates one.**
    ///
    /// This used to fall through to registration when the assertion came back empty, and
    /// that was a way to lose someone's money. iOS returns `.canceled` both when no
    /// credential matched *and* when the user dismissed the sheet — the two are
    /// indistinguishable by code — so a mis-tapped dismissal ran a registration, Mera
    /// minted a fresh user handle, and the new passkey derived a different address. To
    /// the user their funded account had simply vanished, and there is no way back from
    /// it.
    ///
    /// Creating a credential is now `createAccounts()`, reached only by a person choosing
    /// it. Cancellation is cancellation.
    func deriveAccounts() async throws -> DerivedAccounts {
        try requireSupportedSystem()
        return try await derive(from: try await assertExisting())
    }

    /// Creates a passkey, and with it a new wallet.
    ///
    /// Only ever called from an explicit choice, and it refuses outright if this device
    /// has already derived an address. A second passkey for the same relying party is a
    /// second wallet: the first one keeps the funds and nothing in the app can reach them
    /// again. Refusing is the only safe answer, and it is a refusal rather than a warning
    /// because a warning is something people tap through.
    func createAccounts() async throws -> DerivedAccounts {
        try requireSupportedSystem()
        if let existing = store.address {
            throw PasskeyFailure.platformRefused(
                "This device already has a Desk account (\(Self.short(existing))). Creating "
                    + "a second passkey would make a different wallet and leave that one "
                    + "unreachable. Use Face ID to sign in instead.")
        }
        return try await derive(from: try await createNew())
    }

    private func requireSupportedSystem() throws {
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(Self.minimumSystemVersion) else {
            throw PasskeyFailure.prfUnsupported
        }
    }

    private func derive(from output: Data) async throws -> DerivedAccounts {
        var prf = output
        // The bytes exist for exactly as long as the two derivations take.
        defer { prf.resetBytes(in: 0..<prf.count) }
        guard prf.count == 32 else { throw PasskeyFailure.prfReturnedNothing }

        let address = try PasskeyAccounts.deriveAddress(prfOutput: prf)
        let trading = try PasskeyAccounts.deriveTradingKey(prfOutput: prf)
        store.record(address)
        // `hasDesk` is a fact about the chain, not about the passkey. It is read by
        // `BalanceReader` after sign-in rather than guessed here.
        return DerivedAccounts(address: address, trading: trading, hasDesk: false)
    }

    static func short(_ address: EthereumAddress) -> String {
        let text = address.checksummed
        return text.prefix(6) + "…" + text.suffix(4)
    }

    func withKeys<T: Sendable>(
        _ body: @Sendable (WalletKey, TradingKey) async throws -> T
    ) async throws -> T {
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(Self.minimumSystemVersion) else {
            throw PasskeyFailure.prfUnsupported
        }
        var prf = try await assertExisting()
        defer { prf.resetBytes(in: 0..<prf.count) }
        guard prf.count == 32 else { throw PasskeyFailure.prfReturnedNothing }

        // Derived, used, and gone. Neither key leaves this scope and neither is
        // returned, so there is no version of this call that leaves one lying around.
        return try await body(
            try PasskeyAccounts.deriveWalletKey(prfOutput: prf),
            try PasskeyAccounts.deriveTradingKey(prfOutput: prf))
    }

    // MARK: - The two ceremonies

    private func assertExisting() async throws -> Data {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: relyingParty.identifier)
        let request = provider.createCredentialAssertionRequest(challenge: Self.challenge())
        // Spelled the way the overlay actually exposes it: a static member, not an
        // initialiser. Confirmed against the working probe in the sibling app rather
        // than guessed from the Objective-C header, which refines away the init.
        request.prf = .inputValues(
            .init(saltInput1: PasskeyAccounts.prfSalt, saltInput2: nil),
            perCredentialInputValues: nil)
        // Never a passkey the platform would have to guess at, and never a password.
        return try await perform(request, isAssertion: true)
    }

    private func createNew() async throws -> Data {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: relyingParty.identifier)
        // The user handle is the credential's identity to the relying party. It is random
        // because there is no account server to name the user against — the passkey is
        // the account.
        let request = provider.createCredentialRegistrationRequest(
            challenge: Self.challenge(),
            name: displayName,
            userID: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
        // Registration only asks whether PRF is available for this credential; it does
        // not return key material, so the key still comes from an assertion afterwards.
        request.prf = .checkForSupport
        return try await perform(request, isAssertion: false)
    }

    /// Runs one request and pulls the PRF output out of whichever kind of result comes
    /// back.
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
            // Swift refines the output to a `SymmetricKey` rather than raw bytes, so it
            // has to be copied out before it can be used as BIP-39 entropy.
            guard let key = assertion.prf?.first else { throw PasskeyFailure.prfReturnedNothing }
            return Data(key.withUnsafeBytes { Array($0) })
        case let registration as ASAuthorizationPlatformPublicKeyCredentialRegistration:
            // A registration that reports no PRF support is a credential that can never
            // derive a wallet. It is better to fail here than to let the user fund an
            // address they will not be able to reach again.
            // A credential that cannot derive a wallet is worse than no credential: the
            // user would fund an address they could never reach again.
            guard registration.prf?.isSupported == true else { throw PasskeyFailure.prfUnsupported }
            // Registration confirms support but returns no key material, so the key comes
            // from an assertion against the credential just made. Safe to call here and
            // only here: a credential certainly exists, because it was created a moment
            // ago by this same call.
            return try await assertExisting()
        default:
            throw PasskeyFailure.platformRefused("That credential can't be used with Desk.")
        }
    }

    /// A random challenge.
    ///
    /// There is no server to issue one, and that is not a weakness here: the challenge
    /// guards against replay of an *authentication assertion to a server*, and Desk has no
    /// server to replay one to. What matters is the PRF output, which depends on the
    /// credential and the salt and not on the challenge at all.
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

/// Bridges the delegate callbacks to one continuation, resumed exactly once.
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

    /// The platform's error codes, turned into the app's own vocabulary.
    ///
    /// `.canceled` is the interesting one: it is returned both when the user dismisses the
    /// sheet and when there was no credential to offer them. The two are indistinguishable
    /// by code, which is why the flow treats a cancelled assertion as "try creating one"
    /// rather than as a refusal.
    /// The platform's error codes, kept distinguishable.
    ///
    /// The first version mapped `.canceled`, `.notHandled` and `.failed` all to
    /// `noCredentialFound`, which made every possible failure — a domain that is not
    /// associated, a provisioning profile without the capability, a network the device
    /// could not reach Apple's CDN over — present as "no passkey on this device yet".
    /// That is the one message guaranteed to send someone hunting in the wrong place, and
    /// it hid a real setup failure behind a sentence about their phone.
    ///
    /// Only `.canceled` now means "there was nothing to offer", because iOS returns it
    /// both when the user dismisses the sheet and when no credential matched. `.failed`
    /// on an assertion almost always means the association has not taken.
    private static func translate(_ error: any Error, isAssertion: Bool) -> any Error {
        guard let authorization = error as? ASAuthorizationError else {
            let underlying = error as NSError
            return PasskeyFailure.platformRefused(
                "Face ID could not finish (\(underlying.domain) \(underlying.code)).")
        }
        switch authorization.code {
        case .canceled:
            // iOS returns this both for a dismissed sheet and for no matching credential,
            // and nothing distinguishes them. Treated as a cancellation, because the other
            // reading led to silently creating a second wallet.
            return PasskeyFailure.cancelledByUser
        case .invalidResponse:
            return PasskeyFailure.prfReturnedNothing
        case .failed, .notHandled:
            // The message names the likely cause and what to check, because this is a
            // setup failure and the user cannot fix it by trying again.
            return PasskeyFailure.platformRefused(
                isAssertion
                    ? "This device will not use a passkey for Desk yet. The site "
                        + "association has probably not taken — check the domain serves "
                        + "its file, and that Associated Domains Development is on in "
                        + "Settings › Developer. (code \(authorization.code.rawValue))"
                    : "The passkey could not be created. The app's domain association has "
                        + "probably not taken yet. (code \(authorization.code.rawValue))")
        default:
            return PasskeyFailure.platformRefused(
                "Face ID could not finish (code \(authorization.code.rawValue)).")
        }
    }
}

/// Remembers the address the last successful ceremony derived.
///
/// The address alone, never a key. It exists for the address guard: Apple's synced-passkey
/// bug can return different PRF output on a second device, and an app that rendered that
/// account's zero balance would be telling the user their money is gone. Comparing against
/// the last address makes that visible instead.
struct LastSeenAddressStore: Sendable {
    static let standard = LastSeenAddressStore(key: "desk.lastSeenAddress")

    let key: String

    var address: EthereumAddress? {
        guard let text = UserDefaults.standard.string(forKey: key) else { return nil }
        return EthereumAddress(bytes: Self.hex(text))
    }

    /// Twenty bytes from a 0x-prefixed string, or nothing. Written here rather than
    /// reached for from the chain module: this is a defaults value that may be anything,
    /// including a string some other version of the app wrote.
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
