import DeskAuth
import DeskMoney
import Foundation

/// The other way round: AUSD sold to 0x's AllowanceHolder for MON. The call sends nothing along, and the
/// typed AUSD is approved to the holder first, so that approval is the most a bad route can take. What the
/// route delivers is the holder's business: below the quoted floor it reverts, which simulation shows.
public struct MONSwap: Sendable, Hashable {
    public typealias Failure = AUSDSwap.Failure

    /// The holder: the call's target and the approval's spender.
    public let to: EthereumAddress
    public let data: Data
    public let amount: Money
    public let minimumOut: NativeAmount

    public init(
        chainID: UInt64, to: String, data: String, value: String,
        amount: Money, minimumOut: NativeAmount
    ) throws {
        guard chainID == AUSDSwap.chainID else { throw Failure.wrongChain(chainID) }
        let target = AUSDSwap.strip(to).lowercased()
        guard target == AUSDSwap.allowanceHolder,
              let address = AUSDSwap.bytes(target).flatMap(EthereumAddress.init(bytes:))
        else { throw Failure.unknownContract(to) }
        guard let calldata = AUSDSwap.bytes(AUSDSwap.strip(data)), calldata.count > 4 + 32 * 5 else {
            throw Failure.malformed
        }
        guard calldata.prefix(4).map({ String(format: "%02x", $0) }).joined() == AUSDSwap.execSelector else {
            throw Failure.unexpectedCall
        }
        // Nothing rides along: the AUSD moves by approval, so MON here would be MON given away.
        guard value.isEmpty || value == "0" || value == "0x0", amount.raw > 0 else { throw Failure.amountMismatch }
        guard minimumOut.raw > 0 else { throw Failure.malformed }
        self.to = address
        self.data = calldata
        self.amount = amount
        self.minimumOut = minimumOut
    }
}
