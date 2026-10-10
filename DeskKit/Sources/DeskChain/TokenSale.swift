import DeskAuth
import DeskMoney
import Foundation

/// A Monad token sold for MON through 0x's allowance holder: the mirror of `TokenSwap`.
/// Nothing rides along with the call; the token moves by an approval for exactly the amount
/// sold, made just before, so a bad route can take at most that. The floor is MON in wei.
public struct TokenSale: Sendable, Hashable {
    public typealias Failure = AUSDSwap.Failure

    public let to: EthereumAddress
    public let token: EthereumAddress
    public let data: Data
    public let amountRaw: Int128
    public let minimumOut: NativeAmount

    public init(
        chainID: UInt64, to: String, data: String, value: String,
        token: String, amountRaw: String, minimumOutRaw: String
    ) throws {
        guard chainID == AUSDSwap.chainID else { throw Failure.wrongChain(chainID) }
        let target = AUSDSwap.strip(to).lowercased()
        guard target == AUSDSwap.allowanceHolder,
              let address = AUSDSwap.bytes(target).flatMap(EthereumAddress.init(bytes:))
        else { throw Failure.unknownContract(to) }
        let sold = AUSDSwap.strip(token).lowercased()
        guard sold.count == 40, let tokenAddress = AUSDSwap.bytes(sold).flatMap(EthereumAddress.init(bytes:)),
              sold != AUSDSwap.allowanceHolder
        else { throw Failure.unknownContract(token) }
        guard let calldata = AUSDSwap.bytes(AUSDSwap.strip(data)), calldata.count > 4 + 32 * 5 else {
            throw Failure.malformed
        }
        guard calldata.prefix(4).map({ String(format: "%02x", $0) }).joined() == AUSDSwap.execSelector else {
            throw Failure.unexpectedCall
        }
        // Nothing rides along: the token moves by approval, so MON here would be MON given away.
        guard value.isEmpty || value == "0" || value == "0x0" else { throw Failure.amountMismatch }
        guard amountRaw.allSatisfy(\.isASCIIDigit), !amountRaw.isEmpty, amountRaw.count <= 38,
              let amount = Int128(amountRaw), amount > 0
        else { throw Failure.amountMismatch }
        guard minimumOutRaw.allSatisfy(\.isASCIIDigit), !minimumOutRaw.isEmpty, minimumOutRaw.count <= 38,
              let floor = Int128(minimumOutRaw), floor > 0, let minimum = NativeAmount(raw: floor)
        else { throw Failure.malformed }
        self.to = address
        self.token = tokenAddress
        self.data = calldata
        self.amountRaw = amount
        self.minimumOut = minimum
    }
}
