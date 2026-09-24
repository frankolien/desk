import DeskAuth
import DeskNet
import Foundation

/// JSON-RPC against a Monad node.
public actor MonadRPC {
    public struct Configuration: Sendable {
        public let url: URL
        public let chainID: UInt64

        public init(url: URL, chainID: UInt64) throws {
            guard url.scheme?.lowercased() == "https" else {
                throw Failure.endpointMustBeHTTPS(scheme: url.scheme)
            }
            self.url = url
            self.chainID = chainID
        }

        public static func testnet() throws -> Configuration {
            try Configuration(url: URL(string: "https://testnet-rpc.monad.xyz")!, chainID: 10143)
        }

        /// Real funds.
        public static func mainnet() throws -> Configuration {
            try Configuration(url: URL(string: "https://rpc.monad.xyz")!, chainID: 143)
        }
    }

    public enum Failure: Error, Sendable, Equatable {
        case endpointMustBeHTTPS(scheme: String?)
        case transport(status: Int)
        case malformedResponse(String)
        /// The node answered, and said no. `data` carries the revert, when there is one.
        case rejected(code: Int, message: String, data: Data?)
        case chainMismatch(expected: UInt64, got: UInt64)
    }

    private let configuration: Configuration
    private let transport: any HTTPTransport
    private var nextID = 1

    public init(configuration: Configuration, transport: any HTTPTransport = URLSessionTransport()) {
        self.configuration = configuration
        self.transport = transport
    }

    public var chainID: UInt64 { configuration.chainID }

    // MARK: - Calls

    /// Worth doing once before anything is signed. A node quietly pointed at another
    /// network would take transactions signed for this one and reject them, or worse,
    /// take them.
    public func verifyChain() async throws {
        let reported = try await quantity("eth_chainId", [])
        guard reported == configuration.chainID else {
            throw Failure.chainMismatch(expected: configuration.chainID, got: reported)
        }
    }

    public func blockNumber() async throws -> UInt64 {
        try await quantity("eth_blockNumber", [])
    }

    public func balance(of address: EthereumAddress) async throws -> Data {
        try await call("eth_getBalance", [.string(address.checksummed), .string("latest")]) { value in
            guard let text = value.stringValue else { throw Failure.malformedResponse("eth_getBalance") }
            return try Quantity.bytes(text)
        }
    }

    /// Monad's `pending` equals `latest`, so this never counts what is in flight. That is
    /// what `NonceRegistry` is for.
    public func transactionCount(of address: EthereumAddress) async throws -> UInt64 {
        try await quantity("eth_getTransactionCount", [.string(address.checksummed), .string("latest")])
    }

    public func baseFeePerGas() async throws -> UInt64 {
        let block = try await call("eth_getBlockByNumber", [.string("latest"), .bool(false)]) { value in
            guard case .object(let fields) = value,
                  let fee = fields["baseFeePerGas"]?.stringValue
            else { throw Failure.malformedResponse("baseFeePerGas") }
            return try Quantity.uint64(fee)
        }
        return block
    }

    public func callContract(to: EthereumAddress, data: Data, from: EthereumAddress? = nil) async throws -> Data {
        var request: [String: JSONValue] = [
            "to": .string(to.checksummed),
            "data": .string("0x" + data.map { String(format: "%02x", $0) }.joined()),
        ]
        if let from { request["from"] = .string(from.checksummed) }
        return try await call("eth_call", [.object(request), .string("latest")]) { value in
            guard let text = value.stringValue else { throw Failure.malformedResponse("eth_call") }
            return text == "0x" ? Data() : try ABIWord.hexBytes(text)
        }
    }

    public func estimateGas(
        to: EthereumAddress, data: Data, value: Data = Data(), from: EthereumAddress
    ) async throws -> UInt64 {
        var request: [String: JSONValue] = [
            "from": .string(from.checksummed),
            "to": .string(to.checksummed),
            "data": .string("0x" + data.map { String(format: "%02x", $0) }.joined()),
        ]
        // A payable call estimated without its value can revert, or price a different path.
        if value.contains(where: { $0 != 0 }) { request["value"] = .string(Quantity.encode(value)) }
        return try await quantity("eth_estimateGas", [.object(request)])
    }

    public func sendRawTransaction(_ signed: SignedTransaction) async throws -> String {
        try await call("eth_sendRawTransaction", [.string(signed.rawHex)]) { value in
            guard let text = value.stringValue else { throw Failure.malformedResponse("txHash") }
            return text
        }
    }

    public func receipt(for hash: String) async throws -> TransactionReceipt? {
        try await call("eth_getTransactionReceipt", [.string(hash)]) { value in
            guard case .object(let fields) = value else { return nil }
            guard let status = fields["status"]?.stringValue else {
                throw Failure.malformedResponse("receipt.status")
            }
            return TransactionReceipt(
                hash: hash,
                succeeded: (try? Quantity.uint64(status)) == 1,
                gasUsed: fields["gasUsed"]?.stringValue.flatMap { try? Quantity.uint64($0) },
                blockNumber: fields["blockNumber"]?.stringValue.flatMap { try? Quantity.uint64($0) })
        }
    }

    /// One block of calls run against the latest state, none of them signed or sent.
    ///
    /// This is how a transaction someone else composed is checked before the wallet key
    /// touches it: the call runs, and a balance read in the same block says what it would
    /// have left behind. `eth_simulateV1` is served by Monad's public node.
    public func simulate(_ calls: [SimulatedCall]) async throws -> [SimulatedResult] {
        let encoded: [JSONValue] = calls.map { call in
            var fields: [String: JSONValue] = [
                "to": .string(call.to.checksummed),
                "data": .string("0x" + call.data.map { String(format: "%02x", $0) }.joined()),
            ]
            if let from = call.from { fields["from"] = .string(from.checksummed) }
            if call.value.contains(where: { $0 != 0 }) { fields["value"] = .string(Quantity.encode(call.value)) }
            return .object(fields)
        }
        let request: JSONValue = .object([
            "blockStateCalls": .array([.object(["calls": .array(encoded)])]),
            "validation": .bool(false),
            "traceTransfers": .bool(false),
        ])
        return try await call("eth_simulateV1", [request, .string("latest")]) { value in
            guard case .array(let blocks) = value, case .object(let block)? = blocks.first,
                  case .array(let results)? = block["calls"], results.count == calls.count
            else { throw Failure.malformedResponse("eth_simulateV1") }
            return try results.map { result in
                guard case .object(let fields) = result, let status = fields["status"]?.stringValue
                else { throw Failure.malformedResponse("eth_simulateV1.status") }
                let returned = fields["returnData"]?.stringValue ?? "0x"
                return SimulatedResult(
                    succeeded: (try? Quantity.uint64(status)) == 1,
                    returnData: returned == "0x" ? Data() : (try? ABIWord.hexBytes(returned)) ?? Data())
            }
        }
    }

    // MARK: - Machinery

    private func quantity(_ method: String, _ parameters: [JSONValue]) async throws -> UInt64 {
        try await call(method, parameters) { value in
            guard let text = value.stringValue else { throw Failure.malformedResponse(method) }
            return try Quantity.uint64(text)
        }
    }

    private func call<T>(
        _ method: String,
        _ parameters: [JSONValue],
        decode: (JSONValue) throws -> T
    ) async throws -> T {
        let identifier = nextID
        nextID += 1

        var request = URLRequest(url: configuration.url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": identifier,
            "method": method,
            "params": parameters.map(Self.plain),
        ])

        let response = try await transport.send(request)
        guard response.isSuccess else { throw Failure.transport(status: response.status) }

        let envelope = try JSONDecoder().decode(Envelope.self, from: response.body)
        if let error = envelope.error {
            throw Failure.rejected(
                code: error.code,
                message: error.message,
                data: error.data?.stringValue.flatMap { try? ABIWord.hexBytes($0) })
        }
        guard envelope.hasResult else { throw Failure.malformedResponse(method) }
        return try decode(envelope.result)
    }

    /// `"result": null` and no `result` key at all are different answers: the first is
    /// how a node says a transaction is not mined yet, and an optional property collapses
    /// both to `nil`. Polling a receipt is the common case, so the difference is load
    /// bearing.
    private struct Envelope: Decodable {
        let hasResult: Bool
        let result: JSONValue
        let error: RPCError?

        enum CodingKeys: String, CodingKey { case result, error }

        init(from decoder: any Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            error = try box.decodeIfPresent(RPCError.self, forKey: .error)
            hasResult = box.contains(.result)
            result = hasResult ? try box.decode(JSONValue.self, forKey: .result) : .null
        }

        struct RPCError: Decodable {
            let code: Int
            let message: String
            let data: JSONValue?
        }
    }

    /// `JSONValue` back to what `JSONSerialization` will write.
    private static func plain(_ value: JSONValue) -> Any {
        switch value {
        case .string(let text): text
        case .integer(let number): number
        case .number(let text): text
        case .bool(let flag): flag
        case .array(let items): items.map(plain)
        case .object(let fields): fields.mapValues(plain)
        case .null: NSNull()
        }
    }
}

public struct TransactionReceipt: Sendable, Hashable {
    public let hash: String
    public let succeeded: Bool
    public let gasUsed: UInt64?
    public let blockNumber: UInt64?
}

public struct SimulatedCall: Sendable, Hashable {
    public let from: EthereumAddress?
    public let to: EthereumAddress
    public let data: Data
    public let value: Data

    public init(from: EthereumAddress? = nil, to: EthereumAddress, data: Data, value: Data = Data()) {
        self.from = from
        self.to = to
        self.data = data
        self.value = value
    }
}

public struct SimulatedResult: Sendable, Hashable {
    public let succeeded: Bool
    public let returnData: Data
}
