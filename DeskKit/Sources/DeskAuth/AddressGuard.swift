import Foundation

/// Checks a freshly derived address against the one this install last saw.
///
/// There is an open Apple bug in which a passkey synced to a second device can return a
/// different PRF output, which derives a different address. Without this check that
/// failure looks like theft: the user signs in on a new phone, the app derives an empty
/// account, and shows a funded balance as zero. The app compares before it shows a
/// balance, and says what happened rather than rendering a zero.
public enum AddressGuard {
    public enum Verdict: Sendable, Equatable {
        /// Nothing stored yet. Adopt the derived address.
        case firstRun(EthereumAddress)
        case matches(EthereumAddress)
        /// Never show a balance for this. The derivation, not the money, is what moved.
        case differs(stored: EthereumAddress, derived: EthereumAddress)
    }

    public static func check(derived: EthereumAddress, against stored: EthereumAddress?) -> Verdict {
        guard let stored else { return .firstRun(derived) }
        return stored == derived ? .matches(derived) : .differs(stored: stored, derived: derived)
    }
}

extension AddressGuard.Verdict {
    /// The only states in which a balance may be rendered.
    public var mayShowBalance: Bool {
        switch self {
        case .firstRun, .matches: true
        case .differs: false
        }
    }
}
