import DeskAuth
import Foundation
import Testing
@testable import DeskChain

@Suite("Any-chain send")
struct AnyChainSendTests {
    let wallet = EthereumAddress(bytes: AUSDSwap.bytes("e05fcc23807536bee418f142d19fa0d21bb0cff7")!)!
    let bob = "0x0000000000000000000000000000000000000b0b"
    let friendOnSolana = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"
    let contract = "0x41fa5ca5b73fb6ea8e3ca219f8f2bc8ce35fa04e"
    let ausd = "0x00000000efe302beaa2b3e6e1b18d08d69a9012a"
    let depository = "0x4cd00e387622c35bddb9b4c962c136462338bc31"
    let now = Date(timeIntervalSince1970: 1_792_349_900)

    private func word(_ hex: String) -> String { String(repeating: "0", count: 64 - hex.count) + hex }
    private func transfer(_ to: String, _ amountHex: String) -> String { "0xa9059cbb" + word(String(to.dropFirst(2))) + word(amountHex) }
    private func approve(_ spender: String, _ amountHex: String) -> String { "0x095ea7b3" + word(String(spender.dropFirst(2))) + word(amountHex) }
    private func hex(_ data: Data) -> String { "0x" + data.map { String(format: "%02x", $0) }.joined() }

    private func typed(_ json: String) throws -> EIP712.TypedData {
        try JSONDecoder().decode(EIP712.TypedData.self, from: Data(json.utf8))
    }

    private func sendTyped(amount: String = "20000000", nonce: String = "0", deadline: String = "1792350000", callsHash: String, destination: String, verifyingContract: String? = nil, from: String? = nil) throws -> EIP712.TypedData {
        try typed("""
        {"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],
        "Send":[{"name":"from","type":"address"},{"name":"amount","type":"uint256"},{"name":"nonce","type":"uint256"},{"name":"deadline","type":"uint256"},{"name":"callsHash","type":"bytes32"},{"name":"destination","type":"bytes32"}]},
        "primaryType":"Send","domain":{"name":"Desk Send","version":"1","chainId":"143","verifyingContract":"\(verifyingContract ?? contract)"},
        "message":{"from":"\(from ?? "0xe05fcc23807536bee418f142d19fa0d21bb0cff7")","amount":"\(amount)","nonce":"\(nonce)","deadline":"\(deadline)","callsHash":"\(callsHash)","destination":"\(destination)"}}
        """)
    }

    private func permitTyped(value: String = "20000000", nonce: String = "0", deadline: String = "1792350000", spender: String? = nil) throws -> EIP712.TypedData {
        try typed("""
        {"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],
        "Permit":[{"name":"owner","type":"address"},{"name":"spender","type":"address"},{"name":"value","type":"uint256"},{"name":"nonce","type":"uint256"},{"name":"deadline","type":"uint256"}]},
        "primaryType":"Permit","domain":{"name":"AUSD","version":"1","chainId":"143","verifyingContract":"\(ausd)"},
        "message":{"owner":"0xe05fcc23807536bee418f142d19fa0d21bb0cff7","spender":"\(spender ?? contract)","value":"\(value)","nonce":"\(nonce)","deadline":"\(deadline)"}}
        """)
    }

    @Test("a Monad send hashes exactly as the contract and the server do")
    func monadVectors() throws {
        let calls = [(to: ausd, data: transfer(bob, "1312d00"))]
        let callsHash = "0xce53fbff5690ae64ae12014724e1ed578026f4ad97ebb439fa10f1ceed3a097a"
        let destination = "0x9e1dc77c835d4b8e909ceee6398c6a8fc0c65e92c56950f7e41b0d0eb3acfb03"
        #expect(hex(AnyChainSend.hashCalls([.init(to: EthereumAddress(text: ausd)!, data: AUSDSwap.bytes(String(calls[0].data.dropFirst(2)))!)])) == callsHash)
        #expect(hex(AnyChainSend.destinationTag(chainID: 143, recipient: bob)) == destination)
        #expect(hex(AnyChainSend.destinationTag(chainID: 143, recipient: "bob")) == "0xb8824dac87bb649c718a275c3ff6592f35e3066e7c97d6148469fddd6d30ca85")
        let send = try AnyChainSend(
            wallet: wallet, amountRaw: "20000000", destinationChainID: 143, recipient: bob, calls: calls,
            nonce: "0", deadline: "1792350000", callsHash: callsHash, destination: destination,
            send: try sendTyped(callsHash: callsHash, destination: destination), permit: try permitTyped(), now: now)
        #expect(hex(try send.sendDigest()) == "0x0c3ae401ecbf57c6396095a86790c6865e302ae588d66d367c0b332dd10f0faf")
        #expect(try send.permitDigest().count == 32)
    }

    @Test("a Solana send is Relay's approve and deposit, nothing else")
    func solanaRoute() throws {
        let calls = [(to: ausd, data: approve(depository, "1312d00")), (to: depository, data: "0xe8017952" + word("41fa5ca5b73fb6ea8e3ca219f8f2bc8ce35fa04e"))]
        let checked = calls.map { AnyChainSend.Call(to: EthereumAddress(text: $0.to)!, data: AUSDSwap.bytes(String($0.data.dropFirst(2)))!) }
        let callsHash = hex(AnyChainSend.hashCalls(checked))
        let destination = hex(AnyChainSend.destinationTag(chainID: 792_703_809, recipient: friendOnSolana))
        let send = try AnyChainSend(
            wallet: wallet, amountRaw: "20000000", destinationChainID: 792_703_809, recipient: friendOnSolana, calls: calls,
            nonce: "0", deadline: "1792350000", callsHash: callsHash, destination: destination,
            send: try sendTyped(callsHash: callsHash, destination: destination), permit: try permitTyped(), now: now)
        #expect(send.calls.count == 2)

        // An approval to a stranger, a transfer on a cross-chain send, a call to a stranger: refused.
        let stranger = [(to: ausd, data: approve(bob, "1312d00")), calls[1]]
        #expect(throws: AnyChainSend.Failure.callNotAllowed("00000000efe302beaa2b3e6e1b18d08d69a9012a")) {
            try AnyChainSend(wallet: wallet, amountRaw: "20000000", destinationChainID: 792_703_809, recipient: friendOnSolana, calls: stranger, nonce: "0", deadline: "1792350000", callsHash: callsHash, destination: destination, send: try sendTyped(callsHash: callsHash, destination: destination), permit: try permitTyped(), now: now)
        }
        let moved = [(to: ausd, data: transfer(bob, "1312d00"))]
        #expect(throws: AnyChainSend.Failure.callsNotAsExpected) {
            try AnyChainSend(wallet: wallet, amountRaw: "20000000", destinationChainID: 792_703_809, recipient: friendOnSolana, calls: moved, nonce: "0", deadline: "1792350000", callsHash: callsHash, destination: destination, send: try sendTyped(callsHash: callsHash, destination: destination), permit: try permitTyped(), now: now)
        }
        let elsewhere = [(to: bob, data: "0x")]
        #expect(throws: AnyChainSend.Failure.callNotAllowed("0000000000000000000000000000000000000b0b")) {
            try AnyChainSend(wallet: wallet, amountRaw: "20000000", destinationChainID: 792_703_809, recipient: friendOnSolana, calls: elsewhere, nonce: "0", deadline: "1792350000", callsHash: callsHash, destination: destination, send: try sendTyped(callsHash: callsHash, destination: destination), permit: try permitTyped(), now: now)
        }
    }

    @Test("what the server sends to sign must match what the person asked for")
    func typedDataIsChecked() throws {
        let calls = [(to: ausd, data: transfer(bob, "1312d00"))]
        let callsHash = "0xce53fbff5690ae64ae12014724e1ed578026f4ad97ebb439fa10f1ceed3a097a"
        let destination = "0x9e1dc77c835d4b8e909ceee6398c6a8fc0c65e92c56950f7e41b0d0eb3acfb03"
        func make(send: EIP712.TypedData? = nil, permit: EIP712.TypedData? = nil, amount: String = "20000000", deadline: String = "1792350000") throws -> AnyChainSend {
            try AnyChainSend(wallet: wallet, amountRaw: amount, destinationChainID: 143, recipient: bob, calls: calls, nonce: "0", deadline: deadline, callsHash: callsHash, destination: destination,
                             send: try send ?? sendTyped(callsHash: callsHash, destination: destination), permit: try permit ?? permitTyped(), now: now)
        }
        #expect(throws: AnyChainSend.Failure.contractIsNotDesk(bob)) { try make(send: try sendTyped(callsHash: callsHash, destination: destination, verifyingContract: bob)) }
        #expect(throws: AnyChainSend.Failure.amountNotAsExpected) { try make(send: try sendTyped(amount: "30000000", callsHash: callsHash, destination: destination)) }
        #expect(throws: AnyChainSend.Failure.sendNotAsExpected("from")) { try make(send: try sendTyped(callsHash: callsHash, destination: destination, from: bob)) }
        #expect(throws: AnyChainSend.Failure.permitNotAsExpected) { try make(permit: try permitTyped(spender: bob)) }
        #expect(throws: AnyChainSend.Failure.permitNotAsExpected) { try make(permit: try permitTyped(value: "30000000")) }
        #expect(throws: AnyChainSend.Failure.deadlineNotAsExpected) { try make(deadline: "1792349000") }
        #expect(throws: AnyChainSend.Failure.deadlineNotAsExpected) { try make(deadline: "1792360000") }
        // The transfer must carry the exact amount to the exact recipient.
        #expect(throws: AnyChainSend.Failure.callsNotAsExpected) {
            try AnyChainSend(wallet: wallet, amountRaw: "20000000", destinationChainID: 143, recipient: bob, calls: [(to: ausd, data: transfer("0x0000000000000000000000000000000000000bad", "1312d00"))], nonce: "0", deadline: "1792350000", callsHash: callsHash, destination: destination, send: try sendTyped(callsHash: callsHash, destination: destination), permit: try permitTyped(), now: now)
        }
    }
}
