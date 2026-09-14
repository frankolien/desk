import Foundation

public enum PerplMessage: Int, Sendable, Hashable {
    case orderStatus = 3
    case walletSnapshot = 19
    case account = 21
    case order = 22
    case orderUpdate = 24
    case positionsSnapshot = 26
    case positionsUpdate = 27
    case signIn = 29
}

/// Message type 29. The first thing sent on a new socket and, given the ten-second
/// pre-authentication idle timeout, the only thing that may come before anything slow.
struct SignInFrame: Encodable {
    let messageType = PerplMessage.signIn.rawValue
    let chainID: UInt64
    let apiKey: String
    let timestamp: String
    let nonce: String
    let signature: String

    enum CodingKeys: String, CodingKey {
        case messageType = "mt"
        case chainID = "chain_id"
        case apiKey = "api_key"
        case timestamp, nonce, signature
    }
}

/// An inbound frame, kept as its bytes.
///
/// Only `mt` is read eagerly. Perpl's frame catalogue is larger than what this app has
/// seen on the wire, and a decoder that rejects an unmodelled frame would break the
/// session over a field nobody needed.
public struct InboundFrame: Sendable, Hashable {
    public let messageType: Int
    public let payload: Data

    public var kind: PerplMessage? { PerplMessage(rawValue: messageType) }

    public init(payload: Data) throws {
        struct Envelope: Decodable { let mt: Int }
        self.messageType = try JSONDecoder().decode(Envelope.self, from: payload).mt
        self.payload = payload
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: payload)
    }
}

/// Message type 19. Arriving at all is what proves the sign-in was accepted.
public struct WalletSnapshot: Decodable, Sendable, Hashable {
    public let accounts: [Account]

    public struct Account: Decodable, Sendable, Hashable {
        public let id: UInt32
    }

    public var firstAccount: UInt32? { accounts.first?.id }
}

/// Message type 3.
///
/// `code` zero means the gateway took the order, not that it filled. `sr` is the reason
/// behind a rejection and is the only field that says which of several causes it was.
public struct OrderStatus: Decodable, Sendable, Hashable {
    public let frameID: Int64?
    public let code: Int
    public let subReason: Int?

    public var isAccepted: Bool { code == 0 }

    enum CodingKeys: String, CodingKey {
        case frameID = "sn"
        case code
        case subReason = "sr"
    }
}
