import DeskAuth
import DeskMoney
import Foundation

/// Calldata for the three contracts the phone touches.
///
/// Selectors are derived from their signatures rather than pasted, so a mistyped
/// signature fails a test rather than silently calling the wrong function.
public enum Calldata {
    public static func selector(_ signature: String) -> Data {
        Data(Keccak.hash(signature).prefix(4))
    }

    // MARK: ERC-20

    public static func approve(spender: EthereumAddress, amount: Money) throws -> Data {
        selector("approve(address,uint256)")
            + (try ABIWord.address(spender.checksummed))
            + (try ABIWord.uint(String(amount.raw)))
    }

    public static func balanceOf(_ owner: EthereumAddress) throws -> Data {
        selector("balanceOf(address)") + (try ABIWord.address(owner.checksummed))
    }

    public static func allowance(owner: EthereumAddress, spender: EthereumAddress) throws -> Data {
        selector("allowance(address,address)")
            + (try ABIWord.address(owner.checksummed))
            + (try ABIWord.address(spender.checksummed))
    }

    // MARK: Perpl Exchange

    /// Opens the account with its first collateral. Testnet minimum is 100 AUSD.
    public static func createAccount(amount: Money) throws -> Data {
        selector("createAccount(uint256)") + (try ABIWord.uint(String(amount.raw)))
    }

    public static func depositCollateral(amount: Money) throws -> Data {
        selector("depositCollateral(uint256)") + (try ABIWord.uint(String(amount.raw)))
    }

    /// Mandatory third call. A fresh account has forwarding disabled and every API order
    /// fails with `sr: 34` after being acknowledged as `code: 0`, so the rejection looks
    /// like anything but a missing setup step.
    public static func allowOrderForwarding(_ allow: Bool) -> Data {
        selector("allowOrderForwarding(bool)") + ABIWord.bool(allow)
    }

    /// Withdrawals are contract calls the wallet signs, never the API key.
    public static func withdrawCollateral(amount: Money) throws -> Data {
        selector("withdrawCollateral(uint256)") + (try ABIWord.uint(String(amount.raw)))
    }

    /// Reverts rather than returning zero when no account exists, which is how the app
    /// learns a desk has not been opened.
    public static func getAccountByAddr(_ address: EthereumAddress) throws -> Data {
        selector("getAccountByAddr(address)") + (try ABIWord.address(address.checksummed))
    }

    // MARK: Agora faucet

    /// Pays its argument, not the caller, so a funded wallet can fill any address.
    public static func requestFunds(to recipient: EthereumAddress) throws -> Data {
        selector("requestFunds(address)") + (try ABIWord.address(recipient.checksummed))
    }
}

/// The three reverts seen from the faucet, as their four-byte selectors.
public enum FaucetRevert: Sendable, Hashable {
    case cooldownActive
    case recipientAlreadyFunded
    /// `SafeERC20FailedOperation(address)` — confirmed with `cast sig`, and OpenZeppelin's
    /// generic wrapper rather than anything the faucet defines. It is raised for any
    /// failed ERC-20 operation, so an empty faucet is the likely cause but never the only
    /// one, and the sentence shown to the user has to allow for that.
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
