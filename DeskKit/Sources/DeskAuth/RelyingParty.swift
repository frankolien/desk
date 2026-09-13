import Foundation

/// The WebAuthn relying party identifier: the domain a passkey is bound to.
///
/// This is the one value in the app that genuinely cannot be changed later. Every
/// passkey is scoped to it, so changing it after a single user has enrolled orphans
/// their credential and their derived address along with it — there is no migration and
/// no recovery. It is worth a type and a validator rather than a string literal.
///
/// The rules below are WebAuthn's, and the reason each one is here is that the platform
/// rejects the ceremony at runtime rather than at build time: a scheme, a port or a path
/// in this string produces a failed ceremony on a device, not a compiler error.
public struct RelyingParty: Sendable, Hashable, CustomStringConvertible {
    public enum Failure: Error, Equatable, Sendable {
        case empty
        case containsScheme(String)
        case containsPath(String)
        case containsPort(String)
        case containsCredentials(String)
        case notASCII(String)
        case notADomain(String)
        case labelMalformed(String)
        case tooLong(Int)
    }

    public let identifier: String

    public var description: String { identifier }

    /// The entitlement value that must appear in `com.apple.developer.associated-domains`
    /// for this relying party. Derived rather than typed twice: the entitlement and the
    /// ceremony drifting apart is a failure that only shows up on a device.
    public var associatedDomain: String { "webcredentials:\(identifier)" }

    /// Where Apple will fetch the association file from. It must be served over HTTPS
    /// and must not redirect.
    public var associationFileURL: URL {
        URL(string: "https://\(identifier)/.well-known/apple-app-site-association")!
    }

    public init(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { throw Failure.empty }
        guard !trimmed.contains("://") else { throw Failure.containsScheme(text) }
        guard !trimmed.contains("@") else { throw Failure.containsCredentials(text) }
        guard !trimmed.contains("/") else { throw Failure.containsPath(text) }
        guard !trimmed.contains(":") else { throw Failure.containsPort(text) }
        guard trimmed.allSatisfy(\.isASCII) else { throw Failure.notASCII(text) }
        guard trimmed.utf8.count <= 253 else { throw Failure.tooLong(trimmed.utf8.count) }

        // A trailing dot is a valid DNS name and not a valid relying party.
        guard !trimmed.hasSuffix(".") else { throw Failure.notADomain(text) }
        let labels = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        // A bare label has no registrable domain, so no association file can be served
        // for it. That rules out `localhost`, which is why there is no local shortcut.
        guard labels.count >= 2 else { throw Failure.notADomain(text) }

        for label in labels {
            guard !label.isEmpty, label.utf8.count <= 63 else { throw Failure.labelMalformed(String(label)) }
            guard !label.hasPrefix("-"), !label.hasSuffix("-") else {
                throw Failure.labelMalformed(String(label))
            }
            guard label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
                throw Failure.labelMalformed(String(label))
            }
        }
        identifier = trimmed
    }
}

/// Why a passkey ceremony could not produce a key.
///
/// Each case carries the sentence the user is shown, because the product document asks
/// for a plain sentence rather than a crash — and, in the PRF case, rather than a silent
/// fallback to a stored key, which is the one outcome this app must never have.
public enum PasskeyFailure: Error, Equatable, Sendable {
    case prfUnsupported
    case prfReturnedNothing
    case cancelledByUser
    case noCredentialFound
    case relyingPartyNotAssociated(RelyingParty)
    case platformRefused(String)

    public var sentence: String {
        switch self {
        case .prfUnsupported:
            "This device can't create the kind of passkey Desk needs. Desk derives your "
                + "trading key from the passkey itself, so there's no way around it."
        case .prfReturnedNothing:
            "Face ID worked, but the passkey didn't return the key material Desk needs. "
                + "Try again, and if it keeps happening this device can't run Desk."
        case .cancelledByUser:
            "Cancelled."
        case .noCredentialFound:
            "No Desk passkey on this device yet. Create one to get started."
        case .relyingPartyNotAssociated(let party):
            "Desk isn't associated with \(party.identifier) yet, so the passkey can't be "
                + "created. This is a setup problem, not something you did."
        case .platformRefused(let reason):
            reason
        }
    }

    /// The one thing no failure may do is fall back to a key kept on the device. There
    /// is no such key, and a case that implied otherwise would be a lie in a type.
    public var mayFallBackToStoredKey: Bool { false }
}
