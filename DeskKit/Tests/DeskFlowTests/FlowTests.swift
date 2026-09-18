import DeskAuth
import DeskChain
import DeskMoney
import DeskNet
import DeskPerpl
import Foundation
import Testing

@testable import DeskFlow

/// Routes by URL path, because a flow talks to the Perpl gateway and a Monad node in the
/// same breath.
final class RoutingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: [HTTPResponse]]
    private var seen: [(path: String, body: Data)] = []

    init(_ routes: [String: [String]]) {
        self.routes = routes.mapValues { $0.map { HTTPResponse(status: 200, body: Data($0.utf8)) } }
    }

    init(responses: [String: [HTTPResponse]]) {
        self.routes = responses
    }

    var requests: [(path: String, body: Data)] { lock.withLock { seen } }

    func bodies(for path: String) -> [Data] {
        lock.withLock { seen.filter { $0.path == path }.map(\.body) }
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.withLock {
            let path = request.url?.path ?? ""
            seen.append((path, request.httpBody ?? Data()))
            // A Monad node is one endpoint for every method, so route JSON-RPC by method.
            let key: String
            if path == "/" || path.isEmpty,
               let body = request.httpBody,
               let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let method = object["method"] as? String {
                key = method
            } else {
                key = path
            }
            guard var queued = routes[key], !queued.isEmpty else {
                return HTTPResponse(status: 404, body: Data(#"{"error":"no route for \#(key)"}"#.utf8))
            }
            let next = queued.removeFirst()
            routes[key] = queued
            return next
        }
    }
}

private func payloadJSON() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "EnrolmentPayload", withExtension: "json"))
    return try Data(contentsOf: url)
}

private let signerAddress = EthereumAddress(bytes: Data(hex: "50b240678777451befd67b7e8c3b4366482ba8f9"))!

private func fakeSigners() -> EnrolmentSigners {
    EnrolmentSigners(
        ed25519PublicKeyHex: { "0x" + String(repeating: "11", count: 32) },
        signWalletDigest: { _ in
            EthereumSignature(r: Data(repeating: 0xaa, count: 32), s: Data(repeating: 0xbb, count: 32), yParity: 1)
        },
        proveEd25519Possession: { _ in Data(repeating: 0xcc, count: 64) })
}

private func signers(publicKeyByte: UInt8) -> EnrolmentSigners {
    EnrolmentSigners(
        ed25519PublicKeyHex: { "0x" + String(repeating: String(format: "%02x", publicKeyByte), count: 32) },
        signWalletDigest: { _ in
            EthereumSignature(r: Data(repeating: 0xaa, count: 32), s: Data(repeating: 0xbb, count: 32), yParity: 1)
        },
        proveEd25519Possession: { _ in Data(repeating: 0xcc, count: 64) })
}

@Suite("Echoing a payload back byte for byte")
struct JSONSpanTests {
    @Test("A nested object comes back exactly as it was written")
    func verbatimObject() throws {
        // Re-encoding would reorder the keys — Swift dictionaries have none — and the
        // mac beside it is over these bytes.
        let document = Data(#"{"a":1,"typed_data":{"z":1,"a":{"nested":[1,2]},"m":"x"},"mac":"0xabc"}"#.utf8)
        let span = try JSONSpan.value(of: "typed_data", in: document)
        #expect(String(decoding: span, as: UTF8.self) == #"{"z":1,"a":{"nested":[1,2]},"m":"x"}"#)
        #expect(String(decoding: try JSONSpan.value(of: "mac", in: document), as: UTF8.self) == "\"0xabc\"")
    }

    @Test("Braces and quotes inside a string do not end the value")
    func escapesRespected() throws {
        let document = Data(#"{"k":{"s":"a \" } ] brace"},"after":1}"#.utf8)
        #expect(String(decoding: try JSONSpan.value(of: "k", in: document), as: UTF8.self)
            == #"{"s":"a \" } ] brace"}"#)
        #expect(String(decoding: try JSONSpan.value(of: "after", in: document), as: UTF8.self) == "1")
    }

    @Test("Pretty-printed JSON is handled")
    func whitespace() throws {
        let document = Data("{\n  \"a\" : 1 ,\n  \"b\" : { \"c\" : true }\n}".utf8)
        #expect(String(decoding: try JSONSpan.value(of: "b", in: document), as: UTF8.self) == "{ \"c\" : true }")
    }

    @Test("A missing key is named")
    func missingKey() {
        #expect(throws: JSONSpan.Failure.keyNotFound("nope")) {
            try JSONSpan.value(of: "nope", in: Data(#"{"a":1,"b":2}"#.utf8))
        }
    }

    @Test("The real payload's typed_data round-trips unchanged")
    func realPayload() throws {
        let document = try payloadJSON()
        let span = try JSONSpan.value(of: "typed_data", in: document)
        // Parses as the same object, and is a byte-for-byte slice of what arrived.
        _ = try JSONDecoder().decode(EIP712.TypedData.self, from: span)
        #expect(document.range(of: span) != nil)
    }
}

@Suite("Enrolment")
struct EnrolmentTests {
    private func rest(_ transport: RoutingTransport) throws -> PerplREST {
        PerplREST(configuration: try .testnet(retry: .none), transport: transport)
    }

    @Test("The payload request carries the key being registered")
    func payloadRequest() async throws {
        let transport = RoutingTransport([
            "/api/v1/api-key/payload": [String(decoding: try payloadJSON(), as: UTF8.self)],
            "/api/v1/api-key/enroll": [#"{"api_key":"pk_live_abc"}"#],
        ])
        let key = try await Enrolment(rest: try rest(transport), chainID: 10143)
            .enrol(address: signerAddress, label: "desk", signers: fakeSigners())
        #expect(key.withValue { $0 } == "pk_live_abc")

        let body = try #require(transport.bodies(for: "/api/v1/api-key/payload").first)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["chain_id"] as? Int == 10143)
        #expect(sent["scope_mask"] as? Int == 3)
        #expect(sent["label"] as? String == "desk")
        #expect(sent["public_key"] as? String == "0x" + String(repeating: "11", count: 32))
    }

    @Test("A key Perpl already registered is passed over for the next derived key")
    func movesPastRegisteredKey() async throws {
        let payload = HTTPResponse(status: 200, body: try payloadJSON())
        let transport = RoutingTransport(responses: [
            "/api/v1/api-key/payload": [payload, payload],
            "/api/v1/api-key/enroll": [
                HTTPResponse(status: 409, body: Data(#"{"error":"Conflict"}"#.utf8)),
                HTTPResponse(status: 200, body: Data(#"{"api_key":"pk_fresh"}"#.utf8)),
            ],
        ])
        let enrolled = try await Enrolment(rest: try rest(transport), chainID: 10143)
            .enrolFirstUnregistered(address: signerAddress, label: "desk", indices: 2..<10) { index in
                signers(publicKeyByte: UInt8(index))
            }
        #expect(enrolled.index == 3)
        #expect(enrolled.apiKey.withValue { $0 } == "pk_fresh")
        let keys = try transport.bodies(for: "/api/v1/api-key/payload").map {
            try #require(try JSONSerialization.jsonObject(with: $0) as? [String: Any])["public_key"] as? String
        }
        #expect(keys == ["0x" + String(repeating: "02", count: 32), "0x" + String(repeating: "03", count: 32)])
    }

    @Test("Running out of candidate keys raises Perpl's own refusal")
    func exhaustsCandidates() async throws {
        let payload = HTTPResponse(status: 200, body: try payloadJSON())
        let conflict = HTTPResponse(status: 409, body: Data(#"{"error":"Conflict"}"#.utf8))
        let transport = RoutingTransport(responses: [
            "/api/v1/api-key/payload": [payload, payload],
            "/api/v1/api-key/enroll": [conflict, conflict],
        ])
        await #expect(throws: PerplREST.Failure.self) {
            try await Enrolment(rest: try rest(transport), chainID: 10143)
                .enrolFirstUnregistered(address: signerAddress, label: "desk", indices: 2..<4) {
                    signers(publicKeyByte: UInt8($0))
                }
        }
    }

    @Test("Any refusal other than already-registered is not retried")
    func otherRefusalsStop() async throws {
        let payload = HTTPResponse(status: 200, body: try payloadJSON())
        let transport = RoutingTransport(responses: [
            "/api/v1/api-key/payload": [payload, payload],
            "/api/v1/api-key/enroll": [HTTPResponse(status: 400, body: Data(#"{"error":"bad"}"#.utf8))],
        ])
        await #expect(throws: PerplREST.Failure.self) {
            try await Enrolment(rest: try rest(transport), chainID: 10143)
                .enrolFirstUnregistered(address: signerAddress, label: "desk", indices: 2..<10) {
                    signers(publicKeyByte: UInt8($0))
                }
        }
        #expect(transport.bodies(for: "/api/v1/api-key/payload").count == 1)
    }

    @Test("The current nested API-key response is accepted")
    func nestedAPIKeyResponse() async throws {
        let transport = RoutingTransport([
            "/api/v1/api-key/payload": [String(decoding: try payloadJSON(), as: UTF8.self)],
            "/api/v1/api-key/enroll": [#"{"api_key":{"api_key":"pk_nested","scope_mask":3}}"#],
        ])
        let key = try await Enrolment(rest: try rest(transport), chainID: 10143)
            .enrol(address: signerAddress, label: "desk", signers: fakeSigners())
        #expect(key.withValue { $0 } == "pk_nested")
    }

    @Test("typed_data and mac go back exactly as they arrived")
    func echoesVerbatim() async throws {
        let document = try payloadJSON()
        let transport = RoutingTransport([
            "/api/v1/api-key/payload": [String(decoding: document, as: UTF8.self)],
            "/api/v1/api-key/enroll": [#"{"api_key":"pk"}"#],
        ])
        _ = try await Enrolment(rest: try rest(transport), chainID: 10143)
            .enrol(address: signerAddress, label: "desk", signers: fakeSigners())

        let body = try #require(transport.bodies(for: "/api/v1/api-key/enroll").first)
        let original = try JSONSpan.value(of: "typed_data", in: document)
        let echoed = try JSONSpan.value(of: "typed_data", in: body)
        #expect(echoed == original)
        #expect(try JSONSpan.value(of: "mac", in: body) == (try JSONSpan.value(of: "mac", in: document)))

        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["signature"] as? String == "0x" + String(repeating: "aa", count: 32) + String(repeating: "bb", count: 32) + "1c")
        #expect(sent["pop_signature"] as? String == "0x" + String(repeating: "cc", count: 64))
    }

    /// The guard, reached through the flow rather than in isolation.
    @Test("A gateway that answers with a permit gets no signature")
    func permitIsRefused() async throws {
        let permit = """
        {"typed_data":{"types":{"EIP712Domain":[{"name":"name","type":"string"},\
        {"name":"version","type":"string"},{"name":"chainId","type":"uint256"},\
        {"name":"verifyingContract","type":"address"}],"Permit":[{"name":"owner","type":"address"},\
        {"name":"spender","type":"address"},{"name":"value","type":"uint256"}]},\
        "primaryType":"Permit","domain":{"name":"AUSD","version":"1","chainId":"0x279f",\
        "verifyingContract":"0xa9012a055bd4e0edff8ce09f960291c09d5322dc"},\
        "message":{"owner":"0x50B240678777451BEfd67B7e8c3b4366482ba8F9",\
        "spender":"0x000000000000000000000000000000000000dEaD","value":"115792089237316195423570985008687907853269984665640564039457584007913129639935"}},\
        "mac":"0xdead"}
        """
        let transport = RoutingTransport([
            "/api/v1/api-key/payload": [permit],
            "/api/v1/api-key/enroll": [#"{"api_key":"pk"}"#],
        ])
        await #expect(throws: (any Error).self) {
            try await Enrolment(rest: try rest(transport), chainID: 10143)
                .enrol(address: signerAddress, label: "desk", signers: fakeSigners())
        }
        // And nothing was sent onward.
        #expect(transport.bodies(for: "/api/v1/api-key/enroll").isEmpty)
    }

    @Test("An enrolment with no key in it is a failure, not an empty key")
    func missingAPIKey() async throws {
        let transport = RoutingTransport([
            "/api/v1/api-key/payload": [String(decoding: try payloadJSON(), as: UTF8.self)],
            "/api/v1/api-key/enroll": [#"{"status":"ok"}"#],
        ])
        await #expect(throws: Enrolment.Failure.apiKeyMissing) {
            try await Enrolment(rest: try rest(transport), chainID: 10143)
                .enrol(address: signerAddress, label: "desk", signers: fakeSigners())
        }
    }

    @Test("Scope and label are bounded before anything is sent")
    func inputBounds() async throws {
        let transport = RoutingTransport([:])
        let enrolment = Enrolment(rest: try rest(transport), chainID: 10143)
        await #expect(throws: Enrolment.Failure.scopeOutOfRange(0)) {
            try await enrolment.enrol(address: signerAddress, label: "d", scopeMask: 0, signers: fakeSigners())
        }
        await #expect(throws: Enrolment.Failure.labelTooLong(65)) {
            try await enrolment.enrol(
                address: signerAddress, label: String(repeating: "x", count: 65), signers: fakeSigners())
        }
        #expect(transport.requests.isEmpty)
    }
}

@Suite("Opening a desk")
struct OpeningSequenceTests {
    private func context() throws -> PerplContext {
        // The flow reads both addresses out of pub/context rather than holding them.
        let json = """
        {"chain":{"chain_id":10143,"name":"Monad Testnet","block_explorer_urls":[]},
         "instances":[{"id":12,"address":"0x1964c32f0be608e7d29302aff5e61268e72080cc",
           "collateral_token_id":1,"min_account_open_amount":"100000000",
           "min_deposit_amount":"10000000","min_withdraw_amount":"10000",
           "max_account_trigger_orders":16}],
         "tokens":[{"id":1,"address":"0xa9012a055bd4e0edff8ce09f960291c09d5322dc",
           "symbol":"AUSD","name":"AUSD","decimals":6,"display_precision":2}],
         "markets":[],"geo_block":[],"features":{"apiKeysEnabled":"on"}}
        """
        return try JSONDecoder().decode(PerplContext.self, from: Data(json.utf8))
    }

    private func sequence(_ transport: RoutingTransport) throws -> OpeningSequence {
        let rpc = MonadRPC(configuration: try .testnet(), transport: transport)
        return OpeningSequence(
            rpc: rpc,
            sender: TransactionSender(rpc: rpc),
            enrolment: Enrolment(
                rest: PerplREST(configuration: try .testnet(retry: .none), transport: transport),
                chainID: 10143),
            addresses: try ExchangeAddresses(context: try context()))
    }

    private func wallet() throws -> WalletKey {
        try WalletKey(privateKey: SecureBytes(
            Data(hex: "4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318")))
    }

    private func word(_ value: UInt64) -> String {
        "0x" + String(format: "%064llx", value)
    }

    @Test("Both addresses come out of pub/context, not out of the source")
    func addressesFromContext() throws {
        let addresses = try ExchangeAddresses(context: try context(), pinnedTo: .testnet)
        #expect(addresses.collateralToken.checksummed.lowercased() == "0xa9012a055bd4e0edff8ce09f960291c09d5322dc")
        #expect(addresses.exchange.checksummed.lowercased() == "0x1964c32f0be608e7d29302aff5e61268e72080cc")
        #expect(addresses.minimumToOpen.text == "100.000000")
    }

    @Test("A venue naming a contract this build does not pin is refused before anything is signed")
    func pinnedAddresses() throws {
        // The fixture is testnet's own context, so testnet's pins match and mainnet's do not.
        #expect(throws: Never.self) { try ExchangeAddresses(context: try context(), pinnedTo: .testnet) }
        #expect(throws: ExchangeAddresses.Failure.self) {
            try ExchangeAddresses(context: try context(), pinnedTo: .mainnet)
        }
    }

    @Test("A deposit under the exchange's own minimum never reaches the chain")
    func belowMinimum() async throws {
        let transport = RoutingTransport([:])
        let deposit = try #require(Money(text: "50"))
        await #expect(throws: OpeningSequence.Failure.belowMinimum(
            deposit: deposit, minimum: try #require(Money(text: "100")))) {
            try await sequence(transport).open(
                wallet: try wallet(), trading: try TradingKey(seed: SecureBytes(Data(repeating: 1, count: 32))),
                deposit: deposit, label: "desk")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("A balance short of the deposit is caught before any gas is spent")
    func insufficientBalance() async throws {
        let transport = RoutingTransport(["eth_call": [#"{"jsonrpc":"2.0","id":1,"result":"\#(word(50_000_000))"}"#]])
        await #expect(throws: (any Error).self) {
            try await sequence(transport).open(
                wallet: try wallet(),
                trading: try TradingKey(seed: SecureBytes(Data(repeating: 1, count: 32))),
                deposit: try #require(Money(text: "100")), label: "desk")
        }
    }

    @Test("A revert from getAccountByAddr means no desk, not an error")
    func revertMeansNoAccount() async throws {
        let transport = RoutingTransport([
            "eth_call": [#"{"jsonrpc":"2.0","id":1,"error":{"code":3,"message":"execution reverted","data":"0x"}}"#]
        ])
        #expect(try await sequence(transport).hasAccount(try wallet().address) == false)
    }

    @Test("An existing account reads back as one")
    func accountExists() async throws {
        let transport = RoutingTransport(["eth_call": [#"{"jsonrpc":"2.0","id":1,"result":"\#(word(7))"}"#]])
        #expect(try await sequence(transport).hasAccount(try wallet().address))
    }

    @Test("A sufficient allowance is not paid for twice")
    func allowanceIsRead() async throws {
        let transport = RoutingTransport(["eth_call": [#"{"jsonrpc":"2.0","id":1,"result":"\#(word(500_000_000))"}"#]])
        #expect(try await sequence(transport).allowance(owner: try wallet().address).text == "500.000000")
    }

    @Test("An unlimited allowance is clamped, never wrapped")
    func unlimitedAllowance() {
        // ERC-20 approvals are routinely set to the uint256 maximum. Wrapping that would
        // show a tiny number and send an approval the user did not need.
        let maximum = Data(repeating: 0xff, count: 32)
        #expect(OpeningSequence.money(maximum).raw == Money.maxRaw)
        #expect(OpeningSequence.money(Data()) == .zero)
        #expect(OpeningSequence.money(Data(repeating: 0, count: 32)) == .zero)
    }
}


extension Data {
    init(hex: String) {
        precondition(hex.count % 2 == 0)
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                preconditionFailure("not hex: \(hex[index..<next])")
            }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
