import DeskAuth
import DeskMoney
import Foundation

/// `RelayDeposit` paid in AUSD: Relay's `depositErc20` on its depository, on Monad mainnet,
/// crediting this wallet, for exactly the typed AUSD, which the wallet approves to the
/// depository just before, so a bad route can take at most that. Nothing rides along.
public struct RelayTokenDeposit: Sendable, Hashable {
    public typealias Failure = RelayDeposit.Failure

    public static let ausd = "00000000efe302beaa2b3e6e1b18d08d69a9012a"
    /// `depositErc20(address,address,uint256,bytes32)`.
    public static let depositERC20Selector = "e8017952"

    public let to: EthereumAddress
    public let token: EthereumAddress
    public let data: Data
    public let amount: Money

    public init(
        chainID: UInt64, to: String, data: String, value: String,
        wallet: EthereumAddress, amount: Money
    ) throws {
        guard chainID == RelayDeposit.chainID else { throw Failure.wrongChain(chainID) }
        let target = AUSDSwap.strip(to).lowercased()
        guard target == RelayDeposit.depository, let address = AUSDSwap.bytes(target).flatMap(EthereumAddress.init(bytes:)) else {
            throw Failure.unknownContract(to)
        }
        guard let calldata = AUSDSwap.bytes(AUSDSwap.strip(data)), calldata.count == 4 + 32 * 4 else {
            throw Failure.malformed
        }
        guard calldata.prefix(4).map({ String(format: "%02x", $0) }).joined() == Self.depositERC20Selector else {
            throw Failure.unexpectedCall
        }
        let word = { (index: Int) in calldata.dropFirst(4 + 32 * index).prefix(32) }
        guard word(0).prefix(12).allSatisfy({ $0 == 0 }), Data(word(0).suffix(20)) == wallet.bytes else {
            throw Failure.depositorIsNotThisWallet
        }
        guard let ausd = AUSDSwap.bytes(Self.ausd).flatMap(EthereumAddress.init(bytes:)),
              word(1).prefix(12).allSatisfy({ $0 == 0 }), Data(word(1).suffix(20)) == ausd.bytes
        else { throw Failure.unexpectedCall }
        guard amount.raw > 0, Data(word(2)) == (try ABIWord.uint(String(amount.raw))),
              value.isEmpty || value == "0" || value == "0x0"
        else { throw Failure.amountMismatch }
        self.to = address
        self.token = ausd
        self.data = calldata
        self.amount = amount
    }
}
