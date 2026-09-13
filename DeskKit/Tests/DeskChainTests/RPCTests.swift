import DeskAuth
import DeskNet
import Foundation
import Testing

@testable import DeskChain

private final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [HTTPResponse]
    private var seen: [Data] = []

    init(_ bodies: [String]) {
        queued = bodies.map { HTTPResponse(status: 200, body: Data($0.utf8)) }
    }

    var requests: [[String: Any]] {
        lock.withLock {
            seen.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.withLock {
            seen.append(request.httpBody ?? Data())
            return queued.isEmpty ? HTTPResponse(status: 500, body: Data()) : queued.removeFirst()
        }
    }
}

private func rpc(_ transport: ScriptedTransport) throws -> MonadRPC {
    MonadRPC(configuration: try .testnet(), transport: transport)
}

@Suite("Quantities")
struct QuantityTests {
    @Test("Zero renders as 0x0, never 0x or 0x00")
    func zero() {
        #expect(Quantity.encode(UInt64(0)) == "0x0")
        #expect(Quantity.encode(Data()) == "0x0")
        #expect(Quantity.encode(Data([0, 0])) == "0x0")
    }

    @Test("Rendering drops leading zeros")
    func noLeadingZeros() {
        #expect(Quantity.encode(UInt64(1)) == "0x1")
        #expect(Quantity.encode(UInt64(255)) == "0xff")
        #expect(Quantity.encode(Data([0x00, 0x01, 0x00])) == "0x100")
    }

    @Test("Parsing tolerates what rendering would not emit")
    func lenientParsing() throws {
        #expect(try Quantity.uint64("0x0") == 0)
        #expect(try Quantity.uint64("0x00000001") == 1)
        #expect(try Quantity.uint64("0xff") == 255)
        #expect(try Quantity.uint64("0x8f0d180") == 150_000_000)
    }

    @Test("A balance too large for UInt64 throws rather than wrapping")
    func balanceOverflow() throws {
        // Eighteen decimals outgrows a UInt64 at about eighteen units, and a wrapped
        // balance is a number the user would act on.
        let eighteenMON = "0xfffffffffffffffff"
        #expect(throws: Quantity.Failure.tooLargeForUInt64(eighteenMON)) {
            try Quantity.uint64(eighteenMON)
        }
        #expect(try Quantity.bytes(eighteenMON).count == 9)
    }

    @Test("A non-quantity is refused")
    func rejected() {
        for text in ["", "0x", "123", "0xzz", "+0x1"] {
            #expect(throws: (any Error).self, "\(text)") { try Quantity.uint64(text) }
        }
    }
}

@Suite("Monad RPC")
struct MonadRPCTests {
    @Test("A plain-HTTP endpoint is refused at construction")
    func httpsOnly() {
        #expect(throws: MonadRPC.Failure.endpointMustBeHTTPS(scheme: "http")) {
            try MonadRPC.Configuration(url: URL(string: "http://testnet-rpc.monad.xyz")!, chainID: 10143)
        }
    }

    @Test("The request is JSON-RPC 2.0 and its id moves")
    func requestShape() async throws {
        let transport = ScriptedTransport([#"{"jsonrpc":"2.0","id":1,"result":"0x279f"}"#, #"{"jsonrpc":"2.0","id":2,"result":"0x3b4832d"}"#])
        let client = try rpc(transport)
        try await client.verifyChain()
        _ = try await client.blockNumber()

        let requests = transport.requests
        #expect(requests.count == 2)
        #expect(requests[0]["jsonrpc"] as? String == "2.0")
        #expect(requests[0]["method"] as? String == "eth_chainId")
        #expect(requests[1]["method"] as? String == "eth_blockNumber")
        #expect(requests[0]["id"] as? Int == 1)
        #expect(requests[1]["id"] as? Int == 2)
    }

    @Test("A node on another chain is caught before anything is signed")
    func chainMismatch() async throws {
        let transport = ScriptedTransport([#"{"jsonrpc":"2.0","id":1,"result":"0x1"}"#])
        await #expect(throws: MonadRPC.Failure.chainMismatch(expected: 10143, got: 1)) {
            try await rpc(transport).verifyChain()
        }
    }

    @Test("A revert comes back with its selector intact")
    func revertData() async throws {
        let transport = ScriptedTransport([
            #"{"jsonrpc":"2.0","id":1,"error":{"code":3,"message":"execution reverted","data":"0x5274afe7"}}"#
        ])
        let faucet = EthereumAddress(bytes: Data(hex: "d236c18d274e54faccc3dd9dda4b27965a73ee6c"))!
        let wallet = EthereumAddress(bytes: Data(hex: "50b240678777451befd67b7e8c3b4366482ba8f9"))!
        do {
            _ = try await rpc(transport).estimateGas(
                to: faucet, data: try Calldata.requestFunds(to: wallet), from: wallet)
            Issue.record("should have thrown")
        } catch let failure as MonadRPC.Failure {
            guard case .rejected(let code, _, let data) = failure else {
                Issue.record("wrong failure: \(failure)")
                return
            }
            #expect(code == 3)
            // The selector survives so the screen can say which revert it was.
            #expect(FaucetRevert(selector: try #require(data)) == .transferFailed)
        }
    }

    @Test("An empty eth_call result is empty data, not a failure")
    func emptyCallResult() async throws {
        let transport = ScriptedTransport([#"{"jsonrpc":"2.0","id":1,"result":"0x"}"#])
        let token = EthereumAddress(bytes: Data(hex: "a9012a055bd4e0edff8ce09f960291c09d5322dc"))!
        let wallet = EthereumAddress(bytes: Data(hex: "50b240678777451befd67b7e8c3b4366482ba8f9"))!
        let result = try await rpc(transport).callContract(to: token, data: try Calldata.balanceOf(wallet))
        #expect(result.isEmpty)
    }

    @Test("A missing receipt is nil rather than an error")
    func pendingReceipt() async throws {
        let transport = ScriptedTransport([#"{"jsonrpc":"2.0","id":1,"result":null}"#])
        #expect(try await rpc(transport).receipt(for: "0xabc") == nil)
    }

    @Test("A reverted transaction is a receipt that says so, not a throw")
    func failedReceipt() async throws {
        let transport = ScriptedTransport([
            #"{"jsonrpc":"2.0","id":1,"result":{"status":"0x0","gasUsed":"0x5208","blockNumber":"0x3b4832d"}}"#
        ])
        let receipt = try #require(try await rpc(transport).receipt(for: "0xabc"))
        #expect(receipt.succeeded == false)
        #expect(receipt.gasUsed == 21_000)
    }

    @Test("A base fee is read out of the block")
    func baseFee() async throws {
        let transport = ScriptedTransport([
            #"{"jsonrpc":"2.0","id":1,"result":{"number":"0x3b4832d","baseFeePerGas":"0x174876e800"}}"#
        ])
        #expect(try await rpc(transport).baseFeePerGas() == 100_000_000_000)
    }
}

/// Against the real testnet. Off unless `DESK_LIVE=1`, so an ordinary run stays offline
/// and takes no dependency on somebody else's uptime.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DESK_LIVE"] == "1"))
struct LiveMonadTests {
    private let ausd = EthereumAddress(bytes: Data(hex: "a9012a055bd4e0edff8ce09f960291c09d5322dc"))!
    private let faucet = EthereumAddress(bytes: Data(hex: "d236c18d274e54faccc3dd9dda4b27965a73ee6c"))!

    @Test("The node is Monad testnet and its head is moving")
    func chainAndHead() async throws {
        let client = MonadRPC(configuration: try .testnet())
        try await client.verifyChain()
        #expect(try await client.blockNumber() > 62_000_000)
    }

    @Test("The base fee is at or above the hundred gwei floor")
    func baseFee() async throws {
        let fee = try await MonadRPC(configuration: try .testnet()).baseFeePerGas()
        #expect(fee >= GasPolicy.minimumFeeWei)
    }

    /// Selector, ABI encoding, RPC envelope and quantity decoding, end to end against a
    /// contract nobody here deployed.
    @Test("The faucet's AUSD balance reads back through our own calldata")
    func faucetBalance() async throws {
        let client = MonadRPC(configuration: try .testnet())
        let result = try await client.callContract(to: ausd, data: try Calldata.balanceOf(faucet))
        #expect(result.count == 32)
        let balance = result.reduce(Int128(0)) { $0 << 8 | Int128($1) }
        // Six decimals, and it held 670,000 AUSD on 11 September.
        #expect(balance > 1_000_000)
    }
}

@Suite("Sending")
struct TransactionSenderTests {
    private let ausd = EthereumAddress(bytes: Data(hex: "a9012a055bd4e0edff8ce09f960291c09d5322dc"))!

    private func key() throws -> WalletKey {
        try WalletKey(privateKey: SecureBytes(
            Data(hex: "4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318")))
    }

    /// estimateGas, baseFeePerGas, transactionCount, sendRawTransaction — in that order.
    private func happyPath(hash: String) -> ScriptedTransport {
        ScriptedTransport([
            #"{"jsonrpc":"2.0","id":1,"result":"0x12ad0"}"#,
            #"{"jsonrpc":"2.0","id":2,"result":{"baseFeePerGas":"0x174876e800"}}"#,
            #"{"jsonrpc":"2.0","id":3,"result":"0x5"}"#,
            #"{"jsonrpc":"2.0","id":4,"result":"\#(hash)"}"#,
        ])
    }

    @Test("A send prices the limit by Monad's margin and numbers itself locally")
    func sendsCorrectly() async throws {
        // The hash is not known until the transaction is built, so the script is filled
        // in from a first pass and the send replayed against it.
        let probe = happyPath(hash: "0x00")
        let sender = TransactionSender(rpc: MonadRPC(configuration: try .testnet(), transport: probe))
        let attempted = try? await sender.send(to: ausd, data: try Calldata.balanceOf(ausd), from: try key())
        #expect(attempted == nil)

        let raw = try #require(probe.requests.last?["params"] as? [Any])
        let rawHex = try #require(raw.first as? String)
        let expected = "0x" + Keccak.hash(try ABIWord.hexBytes(rawHex)).map { String(format: "%02x", $0) }.joined()

        let transport = happyPath(hash: expected)
        let retry = TransactionSender(rpc: MonadRPC(configuration: try .testnet(), transport: transport))
        let signed = try await retry.send(to: ausd, data: try Calldata.balanceOf(ausd), from: try key())

        #expect(signed.hashHex == expected)
        #expect(signed.transaction.nonce == 5)
        #expect(signed.transaction.gasLimit == (try GasPolicy.gasLimit(estimate: 0x12ad0)))
        #expect(signed.transaction.maxFeePerGas == GasPolicy.maxFeePerGas(baseFeeWei: 100_000_000_000))
        #expect(signed.transaction.chainID == 10143)

        let methods = transport.requests.compactMap { $0["method"] as? String }
        #expect(methods == ["eth_estimateGas", "eth_getBlockByNumber", "eth_getTransactionCount", "eth_sendRawTransaction"])
    }

    @Test("A node answering with somebody else's hash is not believed")
    func hashMismatch() async throws {
        let transport = happyPath(hash: "0x" + String(repeating: "ab", count: 32))
        let sender = TransactionSender(rpc: MonadRPC(configuration: try .testnet(), transport: transport))
        await #expect(throws: (any Error).self) {
            try await sender.send(to: ausd, data: try Calldata.balanceOf(ausd), from: try key())
        }
    }

    @Test("A send that never left gives its nonce back")
    func nonceReleasedOnFailure() async throws {
        // Without this every later send in the session is numbered one too high and
        // waits in the mempool for a transaction that will never arrive.
        let nonces = NonceRegistry()
        let failing = ScriptedTransport([
            #"{"jsonrpc":"2.0","id":1,"result":"0x12ad0"}"#,
            #"{"jsonrpc":"2.0","id":2,"result":{"baseFeePerGas":"0x174876e800"}}"#,
            #"{"jsonrpc":"2.0","id":3,"result":"0x5"}"#,
            #"{"jsonrpc":"2.0","id":4,"error":{"code":-32000,"message":"already known"}}"#,
        ])
        let sender = TransactionSender(
            rpc: MonadRPC(configuration: try .testnet(), transport: failing), nonces: nonces)
        await #expect(throws: (any Error).self) {
            try await sender.send(to: ausd, data: try Calldata.balanceOf(ausd), from: try key())
        }
        let wallet = try key().address
        #expect(try await nonces.reserve(for: wallet, chainCount: 5) == 5)
    }

    @Test("A reverted transaction is raised, not returned as a receipt")
    func revertedReceipt() async throws {
        let transport = ScriptedTransport([
            #"{"jsonrpc":"2.0","id":1,"result":{"status":"0x0","gasUsed":"0x5208"}}"#
        ])
        let sender = TransactionSender(rpc: MonadRPC(configuration: try .testnet(), transport: transport))
        let signed = Transaction(
            chainID: 10143, nonce: 0, maxPriorityFeePerGas: 0, maxFeePerGas: 0,
            gasLimit: 21_000, to: ausd
        ).signed(with: EthereumSignature(r: Data(repeating: 1, count: 32), s: Data(repeating: 2, count: 32), yParity: 0))
        await #expect(throws: TransactionSender.Failure.reverted(hash: signed.hashHex)) {
            try await sender.wait(for: signed, timeout: .seconds(1), poll: .milliseconds(10))
        }
    }
}
