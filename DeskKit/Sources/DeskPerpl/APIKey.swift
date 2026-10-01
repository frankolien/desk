import DeskAuth
import Foundation

/// Perpl's opaque API token. Reflection prints private stored properties, so both
/// descriptions are overridden to hide it, and `withValue` is the only way out.
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

/// `sign` is a closure, not a key: holding a `PerplSigner` would keep its `SecureBytes` alive
/// past the session's end, and the next order would not ask for Face ID.
public struct PerplCredentials: Sendable {
    public let apiKey: APIKey
    public let sign: @Sendable (String) async throws -> String

    public init(apiKey: APIKey, sign: @escaping @Sendable (String) async throws -> String) {
        self.apiKey = apiKey
        self.sign = sign
    }

    public init(apiKey: APIKey, signer: PerplSigner) {
        self.init(apiKey: apiKey, sign: { try signer.sign($0) })
    }

    public init(apiKey: APIKey, session: SigningSession) {
        self.init(apiKey: apiKey) { canonical in
            try await session.withTradingKey { key in
                try PerplSigner(seed: key.seed).sign(canonical)
            }
        }
    }
}
