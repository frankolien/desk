import DeskAuth
import DeskMoney
import Foundation

public enum Calldata {
    public static func selector(_ signature: String) -> Data {
        Data(Keccak.hash(signature).prefix(4))
    }

    public static func approve(spender: EthereumAddress, amount: Money) throws -> Data {
        selector("approve(address,uint256)")
            + (try ABIWord.address(spender.checksummed))
            + (try ABIWord.uint(String(amount.raw)))
    }

    /// An approval for a raw token count, whatever the token's decimals.
    public static func approve(spender: EthereumAddress, raw: Int128) throws -> Data {
        selector("approve(address,uint256)")
            + (try ABIWord.address(spender.checksummed))
            + (try ABIWord.uint(String(raw)))
    }

    public static func decimals() -> Data { selector("decimals()") }

    public static func balanceOf(_ owner: EthereumAddress) throws -> Data {
        selector("balanceOf(address)") + (try ABIWord.address(owner.checksummed))
    }

    public static func allowance(owner: EthereumAddress, spender: EthereumAddress) throws -> Data {
        selector("allowance(address,address)")
            + (try ABIWord.address(owner.checksummed))
            + (try ABIWord.address(spender.checksummed))
    }

    public static func createAccount(amount: Money) throws -> Data {
        selector("createAccount(uint256)") + (try ABIWord.uint(String(amount.raw)))
    }

    public static func depositCollateral(amount: Money) throws -> Data {
        selector("depositCollateral(uint256)") + (try ABIWord.uint(String(amount.raw)))
    }

    /// Mandatory third call: without it every API order is acknowledged as `code: 0` and then
    /// fails with `sr: 34`.
    public static func allowOrderForwarding(_ allow: Bool) -> Data {
        selector("allowOrderForwarding(bool)") + ABIWord.bool(allow)
    }

    public static func transfer(to recipient: EthereumAddress, amount: Money) throws -> Data {
        selector("transfer(address,uint256)")
            + (try ABIWord.address(recipient.checksummed))
            + (try ABIWord.uint(String(amount.raw)))
    }

    /// Withdrawals are contract calls the wallet signs, never the API key.
    public static func withdrawCollateral(amount: Money) throws -> Data {
        selector("withdrawCollateral(uint256)") + (try ABIWord.uint(String(amount.raw)))
    }

    /// Reverts rather than returning zero when no account exists; that is how the app learns of it.
    public static func getAccountByAddr(_ address: EthereumAddress) throws -> Data {
        selector("getAccountByAddr(address)") + (try ABIWord.address(address.checksummed))
    }

    public static func requestFunds(to recipient: EthereumAddress) throws -> Data {
        selector("requestFunds(address)") + (try ABIWord.address(recipient.checksummed))
    }
}

public enum FaucetRevert: Sendable, Hashable {
    case cooldownActive
    case recipientAlreadyFunded
    /// OpenZeppelin's generic `SafeERC20FailedOperation(address)`: an empty faucet is likely, never certain.
    case transferFailed

    public init?(selector: Data) {
        switch selector.prefix(4).map({ String(format: "%02x", $0) }).joined() {
        case "20e5bc67": self = .cooldownActive
        case "0949dab9": self = .recipientAlreadyFunded
        case "5274afe7": self = .transferFailed
        default: return nil
        }
    }
}
