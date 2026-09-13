import DeskAuth
import Foundation

/// Perpl's opaque API token.
///
/// The conformances below are the whole point of the type. A `private let text: String`
/// alone does not hide anything: Swift's reflection prints stored properties regardless
/// of access control, so `"\(key)"` on a bare struct yields `APIKey(text: "pk_live_…")`
/// straight into whatever string it was built for. Overriding both descriptions is what
/// closes that, and `withValue` is the only way out.
public struct APIKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let text: String

    public init(_ text: String) { self.text = text }

    public func withValue<T>(_ body: (String) throws -> T) rethrows -> T { try body(text) }

    public var isEmpty: Bool { text.isEmpty }

    public var description: String { "APIKey(hidden)" }
    public var debugDescription: String { description }
}

// Deliberately absent: Codable, Equatable, Hashable. An `==` invites a timing oracle and
// a `Codable` invites the key into a cache file; neither is needed to send a header.

/// What the client needs to authenticate: the token that names the key, and a way to
/// sign with it.
///
/// `sign` is a function, not a key. Holding a `PerplSigner` here would mean holding its
/// `SecureBytes`, and a client that retains those keeps the trading key alive for as
/// long as it holds credentials — so ending the session, or backgrounding the app, would
/// zero nothing and the next order would not ask for Face ID. Handing over a closure
/// keeps the key on the far side of the boundary, where the session can still end it.
public struct PerplCredentials: Sendable {
    public let apiKey: APIKey
    public let sign: @Sendable (String) async throws -> String

    public init(apiKey: APIKey, sign: @escaping @Sendable (String) async throws -> String) {
        self.apiKey = apiKey
        self.sign = sign
    }

    /// For a signer whose lifetime the caller is managing itself — tests, and the
    /// reference checks against the Node script.
    public init(apiKey: APIKey, signer: PerplSigner) {
        self.init(apiKey: apiKey, sign: { try signer.sign($0) })
    }

    /// The way the app builds these. The session owns the key; this borrows it for the
    /// length of one signature and throws once the session has ended.
    public init(apiKey: APIKey, session: SigningSession) {
        self.init(apiKey: apiKey) { canonical in
            try await session.withTradingKey { key in
                try PerplSigner(seed: key.seed).sign(canonical)
            }
        }
    }
}
