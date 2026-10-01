import CryptoKit
import DeskAuth
import DeskChain
import DeskPerpl
import Foundation

public struct EnrolmentSigners: Sendable {
    public let ed25519PublicKeyHex: @Sendable () throws -> String
    public let signWalletDigest: @Sendable (Data) throws -> EthereumSignature
    public let proveEd25519Possession: @Sendable (Data) throws -> Data

    public init(
        ed25519PublicKeyHex: @escaping @Sendable () throws -> String,
        signWalletDigest: @escaping @Sendable (Data) throws -> EthereumSignature,
        proveEd25519Possession: @escaping @Sendable (Data) throws -> Data
    ) {
        self.ed25519PublicKeyHex = ed25519PublicKeyHex
        self.signWalletDigest = signWalletDigest
        self.proveEd25519Possession = proveEd25519Possession
    }

    public static func using(wallet: WalletKey, trading: TradingKey) -> EnrolmentSigners {
        EnrolmentSigners(
            ed25519PublicKeyHex: { "0x" + trading.publicKey.map { String(format: "%02x", $0) }.joined() },
            signWalletDigest: { try WalletSigner.sign(digest: $0, with: wallet) },
            proveEd25519Possession: { digest in
                try trading.seed.withUnsafeBytes { bytes in
                    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(bytes))
                    return try key.signature(for: digest)
                }
            })
    }
}

public struct Enrolment: Sendable {
    public enum Failure: Error, Sendable, Equatable {
        case scopeOutOfRange(Int)
        case labelTooLong(Int)
        case apiKeyMissing
        case noCandidateKeys
    }

    /// Perpl answers 409 for a key it has seen and never reissues its token, so a lost token
    /// is recovered with the next derived key.
    public func enrolFirstUnregistered(
        address: EthereumAddress,
        label: String,
        indices: Range<UInt32>,
        signers: @Sendable (UInt32) throws -> EnrolmentSigners
    ) async throws -> (apiKey: APIKey, index: UInt32) {
        for index in indices {
            do {
                return (try await enrol(address: address, label: label, signers: try signers(index)), index)
            } catch PerplREST.Failure.rejected(status: 409, _) where index + 1 < indices.upperBound {
                continue
            }
        }
        throw Failure.noCandidateKeys
    }

    public static let defaultScopeMask = 3
    public static let maximumLabelLength = 64

    private let rest: PerplREST
    private let chainID: UInt64

    public init(rest: PerplREST, chainID: UInt64) {
        self.rest = rest
        self.chainID = chainID
    }

    public func enrol(
        address: EthereumAddress,
        label: String,
        scopeMask: Int = defaultScopeMask,
        signers: EnrolmentSigners
    ) async throws -> APIKey {
        guard scopeMask > 0, scopeMask <= 0xff else { throw Failure.scopeOutOfRange(scopeMask) }
        guard label.utf8.count <= Self.maximumLabelLength else {
            throw Failure.labelTooLong(label.utf8.count)
        }

        let payloadBody = try JSONSerialization.data(withJSONObject: [
            "chain_id": chainID,
            "address": address.checksummed,
            "public_key": try signers.ed25519PublicKeyHex(),
            "scope_mask": scopeMask,
            "label": label,
        ])
        let payload = try await rest.publicData(
            try PerplEndpoint(method: .post, path: "/v1/api-key/payload", body: payloadBody))

        // Spliced out verbatim, never re-encoded: the mac beside it is over these bytes.
        let typedDataRaw = try JSONSpan.value(of: "typed_data", in: payload)
        let typedData = try JSONDecoder().decode(EIP712.TypedData.self, from: typedDataRaw)

        // The wallet signs only what this asserts, never whatever the gateway chose.
        let digest = try EIP712.digest(
            typedData,
            expecting: .perplEnrolment(signer: address.checksummed, chainID: chainID))

        let walletSignature = try signers.signWalletDigest(digest)
        let possession = try signers.proveEd25519Possession(digest)

        let enrolBody = try Self.enrolRequest(
            chainID: chainID,
            address: address,
            typedDataRaw: typedDataRaw,
            macRaw: try JSONSpan.value(of: "mac", in: payload),
            signature: walletSignature.serialized,
            possession: possession)

        let enrolled = try await rest.publicData(
            try PerplEndpoint(method: .post, path: "/v1/api-key/enroll", body: enrolBody))

        struct Enrolled: Decodable {
            struct Info: Decodable { let api_key: String? }
            let api_key: Value?

            enum Value: Decodable {
                case token(String)
                case info(Info)

                init(from decoder: Decoder) throws {
                    let value = try decoder.singleValueContainer()
                    if let token = try? value.decode(String.self) { self = .token(token) }
                    else { self = .info(try value.decode(Info.self)) }
                }

                var token: String? {
                    switch self {
                    case .token(let token): token
                    case .info(let info): info.api_key
                    }
                }
            }
        }
        guard let key = try JSONDecoder().decode(Enrolled.self, from: enrolled).api_key?.token,
              !key.isEmpty
        else { throw Failure.apiKeyMissing }
        return APIKey(key)
    }

    static func enrolRequest(
        chainID: UInt64,
        address: EthereumAddress,
        typedDataRaw: Data,
        macRaw: Data,
        signature: Data,
        possession: Data
    ) throws -> Data {
        func hex(_ bytes: Data) -> String { "0x" + bytes.map { String(format: "%02x", $0) }.joined() }
        let parts = [
            "\"chain_id\":\(chainID)",
            "\"address\":\"\(address.checksummed)\"",
            "\"typed_data\":\(String(decoding: typedDataRaw, as: UTF8.self))",
            "\"mac\":\(String(decoding: macRaw, as: UTF8.self))",
            "\"signature\":\"\(hex(signature))\"",
            "\"pop_signature\":\"\(hex(possession))\"",
        ]
        return Data(("{" + parts.joined(separator: ",") + "}").utf8)
    }
}
