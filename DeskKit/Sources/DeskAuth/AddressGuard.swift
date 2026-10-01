import Foundation

/// A passkey synced to a second device can return a different PRF output and so a different
/// address; this check runs before any balance is shown, so that never renders as a zero.
public enum AddressGuard {
    public enum Verdict: Sendable, Equatable {
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
    public var mayShowBalance: Bool {
        switch self {
        case .firstRun, .matches: true
        case .differs: false
        }
    }
}
