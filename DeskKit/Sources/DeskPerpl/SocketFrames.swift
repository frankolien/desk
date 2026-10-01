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

/// Message type 29, sent first: the gateway allows ten idle seconds before authentication.
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

public struct WalletSnapshot: Decodable, Sendable, Hashable {
    public let accounts: [Account]

    private enum CodingKeys: String, CodingKey {
        // Perpl's version-235 gateway compacted `accounts` to `as`; both are accepted.
        case accounts
        case compactAccounts = "as"
    }

    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        if let values = try box.decodeIfPresent([Account].self, forKey: .accounts) {
            accounts = values
        } else {
            accounts = try box.decode([Account].self, forKey: .compactAccounts)
        }
    }

    public struct Account: Decodable, Sendable, Hashable {
        public let id: UInt32
        public let instanceID: UInt32?
        /// Perpl's `lfr`, the greatest request id forwarded; the next order's `rq` must exceed it.
        public let lastForwarded: Int64?
        public let balanceRaw: Int64?
        public let lockedRaw: Int64?
        public let isFrozen: Bool
        public let allowsForwarding: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case instanceID = "in"
            case lastForwarded = "lfr"
            case balance = "b"
            case locked = "lb"
            case isFrozen = "fr"
            case allowsForwarding = "fw"
        }

        public init(from decoder: any Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            id = try box.decode(UInt32.self, forKey: .id)
            instanceID = try box.decodeIfPresent(UInt32.self, forKey: .instanceID)
            if !box.contains(.lastForwarded) {
                lastForwarded = nil
            } else if let value = try? box.decode(Int64.self, forKey: .lastForwarded) {
                lastForwarded = value
            } else {
                let text = try box.decode(String.self, forKey: .lastForwarded)
                guard let value = Int64(text) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .lastForwarded, in: box,
                        debugDescription: "lfr is not an Int64")
                }
                lastForwarded = value
            }
            balanceRaw = try Self.decodeWireIntIfPresent(box, key: .balance)
            lockedRaw = try Self.decodeWireIntIfPresent(box, key: .locked)
            isFrozen = (try? box.decode(Bool.self, forKey: .isFrozen)) ?? false
            allowsForwarding = (try? box.decode(Bool.self, forKey: .allowsForwarding)) ?? true
        }

        public var accountUpdate: PerplAccount? {
            guard let instanceID, let balanceRaw else { return nil }
            return PerplAccount(
                instanceID: instanceID, accountID: id,
                isFrozen: isFrozen, allowsForwarding: allowsForwarding,
                balanceRaw: balanceRaw, lockedRaw: lockedRaw ?? 0)
        }

        private static func decodeWireIntIfPresent(
            _ box: KeyedDecodingContainer<CodingKeys>, key: CodingKeys
        ) throws -> Int64? {
            guard box.contains(key) else { return nil }
            if let value = try? box.decode(Int64.self, forKey: key) { return value }
            let text = try box.decode(String.self, forKey: key)
            guard let value = Int64(text) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: box, debugDescription: "account amount is not an Int64")
            }
            return value
        }
    }

    public var firstAccount: UInt32? { accounts.first?.id }
    public var firstLastForwarded: Int64 { accounts.first?.lastForwarded ?? 0 }

    public func account(for instanceID: UInt32) -> Account? {
        accounts.first { $0.instanceID == instanceID }
            ?? accounts.first { $0.instanceID == nil }
    }
}

/// Message type 3. `code` zero means the gateway took the order, not that it filled; `sr` says why
/// a rejection happened.
public struct OrderStatus: Decodable, Sendable, Hashable {
    public let frameID: Int64?
    public let code: Int
    public let subReason: Int?
    public let error: String?

    public var isAccepted: Bool { code == 0 }

    private struct CompactStatus: Decodable {
        let code: Int
        let subReason: Int?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case code
            case subReason = "sr"
            case error
        }
    }

    enum CodingKeys: String, CodingKey {
        case legacyFrameID = "sn"
        case compactFrameID = "cid"
        case code, status, error
        case subReason = "sr"
    }

    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        frameID = try box.decodeIfPresent(Int64.self, forKey: .legacyFrameID)
            ?? box.decodeIfPresent(Int64.self, forKey: .compactFrameID)
        if let legacyCode = try box.decodeIfPresent(Int.self, forKey: .code) {
            code = legacyCode
            subReason = try box.decodeIfPresent(Int.self, forKey: .subReason)
            error = try box.decodeIfPresent(String.self, forKey: .error)
        } else {
            let compact = try box.decode(CompactStatus.self, forKey: .status)
            code = compact.code
            subReason = compact.subReason
            error = compact.error
        }
    }
}
