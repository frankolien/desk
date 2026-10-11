import DeskAuth
import DeskMoney
import Foundation

/// A Monad token bought with AUSD through 0x's allowance holder: `TokenSale` the other way
/// round. Nothing rides along with the call; the AUSD moves by an approval for exactly the
/// typed amount, made just before, so a bad route can take at most that. The floor is the
/// token's raw units, whatever its decimals, and is only ever compared, never displayed.
public struct TokenPurchase: Sendable, Hashable {
    public typealias Failure = AUSDSwap.Failure

    public let to: EthereumAddress
    public let token: EthereumAddress
    public let data: Data
    public let amount: Money
    public let minimumOutRaw: Int128

    public init(
        chainID: UInt64, to: String, data: String, value: String,
        token: String, amount: Money, minimumOutRaw: String
    ) throws {
        guard chainID == AUSDSwap.chainID else { throw Failure.wrongChain(chainID) }
        let target = AUSDSwap.strip(to).lowercased()
        guard target == AUSDSwap.allowanceHolder,
              let address = AUSDSwap.bytes(target).flatMap(EthereumAddress.init(bytes:))
        else { throw Failure.unknownContract(to) }
        let bought = AUSDSwap.strip(token).lowercased()
        guard bought.count == 40, let tokenAddress = AUSDSwap.bytes(bought).flatMap(EthereumAddress.init(bytes:)),
              bought != AUSDSwap.allowanceHolder
        else { throw Failure.unknownContract(token) }
        guard let calldata = AUSDSwap.bytes(AUSDSwap.strip(data)), calldata.count > 4 + 32 * 5 else {
            throw Failure.malformed
        }
        guard calldata.prefix(4).map({ String(format: "%02x", $0) }).joined() == AUSDSwap.execSelector else {
            throw Failure.unexpectedCall
        }
        // Nothing rides along: the AUSD moves by approval, so MON here would be MON given away.
        guard value.isEmpty || value == "0" || value == "0x0", amount.raw > 0 else { throw Failure.amountMismatch }
        guard minimumOutRaw.allSatisfy(\.isASCIIDigit), !minimumOutRaw.isEmpty, minimumOutRaw.count <= 38,
              let floor = Int128(minimumOutRaw), floor > 0
        else { throw Failure.malformed }
        self.to = address
        self.token = tokenAddress
        self.data = calldata
        self.amount = amount
        self.minimumOutRaw = floor
    }
}
