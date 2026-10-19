import DeskAuth
import Foundation

/// A send of the wallet's AUSD to any address on any chain Desk reaches, with Desk paying
/// Monad's gas (docs/any-chain-send.md). The wallet signs two things: an AUSD permit for the
/// DeskSend contract and a Send that pins the exact calls the contract will run. Everything
/// here arrives from Desk's API, so nothing is signed until it has been checked against what
/// the person asked for: the amount, the recipient, the pinned contract, and calls that can
/// only hand AUSD to that recipient on Monad or to Relay for the far chain.
public struct AnyChainSend: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case malformed
        case contractIsNotDesk(String?)
        case callNotAllowed(String)
        case callsNotAsExpected
        case amountNotAsExpected
        case destinationNotAsExpected
        case deadlineNotAsExpected
        case permitNotAsExpected
        case sendNotAsExpected(String)
    }

    /// DeskSend on Monad, at its deterministic address; the same constant the API pins.
    public static let contract = "41fa5ca5b73fb6ea8e3ca219f8f2bc8ce35fa04e"
    public static let ausd = "00000000efe302beaa2b3e6e1b18d08d69a9012a"
    public static let relayDepository = "4cd00e387622c35bddb9b4c962c136462338bc31"
    public static let relayRouter = "ccc88a9d1b4ed6b0eaba998850414b24f1c315be"
    public static let monad: UInt64 = 143
    public static let solana: UInt64 = 792_703_809
    /// A send may be signed this long after the API prepared it.
    public static let deadlineWindow: TimeInterval = 300
    static let approveSelector = "095ea7b3"
    static let transferSelector = "a9059cbb"

    public struct Call: Sendable, Hashable {
        public let to: EthereumAddress
        public let data: Data
    }

    public let wallet: EthereumAddress
    public let amountRaw: String
    public let nonce: String
    public let deadline: String
    public let destinationChainID: UInt64
    public let recipient: String
    public let calls: [Call]
    public let send: EIP712.TypedData
    public let permit: EIP712.TypedData

    public init(
        wallet: EthereumAddress, amountRaw: String, destinationChainID: UInt64, recipient: String,
        calls: [(to: String, data: String)], nonce: String, deadline: String, callsHash: String, destination: String,
        send: EIP712.TypedData, permit: EIP712.TypedData, now: Date = .now
    ) throws {
        guard Self.digits(amountRaw), amountRaw != "0", Self.digits(nonce), Self.digits(deadline),
              let deadlineSeconds = TimeInterval(deadline)
        else { throw Failure.malformed }
        let notBefore = now.timeIntervalSince1970
        guard deadlineSeconds > notBefore, deadlineSeconds <= notBefore + Self.deadlineWindow else { throw Failure.deadlineNotAsExpected }
        guard !calls.isEmpty, calls.count <= 3 else { throw Failure.callsNotAsExpected }

        var checked: [Call] = []
        for call in calls {
            let target = AUSDSwap.strip(call.to).lowercased()
            guard target.count == 40, let address = AUSDSwap.bytes(target).flatMap(EthereumAddress.init(bytes:)),
                  let data = AUSDSwap.bytes(AUSDSwap.strip(call.data))
            else { throw Failure.malformed }
            try Self.check(target: target, data: data, amountRaw: amountRaw, destinationChainID: destinationChainID, recipient: recipient)
            checked.append(Call(to: address, data: data))
        }
        if destinationChainID == Self.monad {
            guard checked.count == 1, checked[0].data.starts(with: AUSDSwap.bytes(Self.transferSelector)!) else { throw Failure.callsNotAsExpected }
        } else {
            guard checked.contains(where: { [Self.relayDepository, Self.relayRouter].contains(Self.hex($0.to.bytes)) }) else { throw Failure.callsNotAsExpected }
        }
        guard Self.sameWord(callsHash, Self.hashCalls(checked)) else { throw Failure.callsNotAsExpected }
        guard Self.sameWord(destination, Self.destinationTag(chainID: destinationChainID, recipient: recipient)) else { throw Failure.destinationNotAsExpected }

        // The Send: from this wallet, this amount, these calls, this recipient, for the pinned contract.
        guard Self.sameAddress(send.domain["verifyingContract"]?.stringValue, Self.contract) else { throw Failure.contractIsNotDesk(send.domain["verifyingContract"]?.stringValue) }
        let sendMessage = send.message
        guard Self.sameAddress(sendMessage["from"]?.stringValue, Self.hex(wallet.bytes)) else { throw Failure.sendNotAsExpected("from") }
        guard Self.sameNumber(sendMessage["amount"]?.stringValue, amountRaw) else { throw Failure.amountNotAsExpected }
        guard Self.sameNumber(sendMessage["nonce"]?.stringValue, nonce) else { throw Failure.sendNotAsExpected("nonce") }
        guard Self.sameNumber(sendMessage["deadline"]?.stringValue, deadline) else { throw Failure.sendNotAsExpected("deadline") }
        guard Self.sameWord(sendMessage["callsHash"]?.stringValue, Self.hashCalls(checked)) else { throw Failure.sendNotAsExpected("callsHash") }
        guard Self.sameWord(sendMessage["destination"]?.stringValue, Self.destinationTag(chainID: destinationChainID, recipient: recipient)) else { throw Failure.sendNotAsExpected("destination") }

        // The permit: AUSD's own, from this wallet to the pinned contract, for the amount, same nonce and deadline.
        guard Self.sameAddress(permit.domain["verifyingContract"]?.stringValue, Self.ausd) else { throw Failure.permitNotAsExpected }
        let permitMessage = permit.message
        guard Self.sameAddress(permitMessage["owner"]?.stringValue, Self.hex(wallet.bytes)),
              Self.sameAddress(permitMessage["spender"]?.stringValue, Self.contract),
              Self.sameNumber(permitMessage["value"]?.stringValue, amountRaw),
              Self.sameNumber(permitMessage["nonce"]?.stringValue, nonce),
              Self.sameNumber(permitMessage["deadline"]?.stringValue, deadline)
        else { throw Failure.permitNotAsExpected }

        self.wallet = wallet
        self.amountRaw = amountRaw
        self.nonce = nonce
        self.deadline = deadline
        self.destinationChainID = destinationChainID
        self.recipient = recipient
        self.calls = checked
        self.send = send
        self.permit = permit
    }

    /// The same fence DeskSend applies on chain: AUSD may go to the recipient (Monad) or be
    /// approved to Relay, for no more than the amount; Relay's contracts take any call.
    private static func check(target: String, data: Data, amountRaw: String, destinationChainID: UInt64, recipient: String) throws {
        if target == relayDepository || target == relayRouter { return }
        guard target == ausd, data.count == 68 else { throw Failure.callNotAllowed(target) }
        let selector = hex(data.prefix(4))
        let argument = hex(data[4..<36].suffix(20))
        let value = Data(data[36..<68])
        let amount = try ABIWord.uint(amountRaw)
        if selector == transferSelector {
            guard destinationChainID == monad, argument == AUSDSwap.strip(recipient).lowercased(), value == amount else { throw Failure.callsNotAsExpected }
            return
        }
        guard selector == approveSelector, [relayDepository, relayRouter].contains(argument) else { throw Failure.callNotAllowed(target) }
        guard value.lexicographicallyPrecedes(amount) || value == amount else { throw Failure.amountNotAsExpected }
    }

    /// keccak256 over (to ‖ keccak256(data)) per call, as DeskSend.hashCalls does.
    public static func hashCalls(_ calls: [Call]) -> Data {
        var packed = Data()
        for call in calls { packed += call.to.bytes + Keccak.hash(call.data) }
        return Keccak.hash(packed)
    }

    /// keccak256 of "<chain>:<recipient>", binding the signature to what was shown.
    public static func destinationTag(chainID: UInt64, recipient: String) -> Data {
        Keccak.hash("\(chainID):\(recipient)")
    }

    public static let sendEncodedType = "Send(address from,uint256 amount,uint256 nonce,uint256 deadline,bytes32 callsHash,bytes32 destination)"
    public static let permitEncodedType = "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
    public static let domainEncodedType = "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"

    public func sendDigest() throws -> Data {
        try EIP712.digest(send, expecting: .init(
            encodedType: Self.sendEncodedType, domainEncodedType: Self.domainEncodedType,
            domainName: "Desk Send", domainVersion: "1", allowedChainIDs: [Self.monad],
            signerField: "from", signer: "0x" + Self.hex(wallet.bytes)))
    }

    public func permitDigest() throws -> Data {
        try EIP712.digest(permit, expecting: .init(
            encodedType: Self.permitEncodedType, domainEncodedType: Self.domainEncodedType,
            domainName: "AUSD", domainVersion: "1", allowedChainIDs: [Self.monad],
            signerField: "owner", signer: "0x" + Self.hex(wallet.bytes)))
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func digits(_ text: String) -> Bool { !text.isEmpty && text.count <= 78 && text.allSatisfy(\.isASCIIDigit) && (text.first != "0" || text == "0") }
    static func sameAddress(_ got: String?, _ want: String) -> Bool { got.map { AUSDSwap.strip($0).lowercased() == want.lowercased() } ?? false }
    static func sameWord(_ got: String?, _ want: Data) -> Bool { got.map { AUSDSwap.strip($0).lowercased() == hex(want) } ?? false }
    static func sameNumber(_ got: String?, _ want: String) -> Bool {
        guard let got, let left = try? ABIWord.uint(got), let right = try? ABIWord.uint(want) else { return false }
        return left == right
    }
}
