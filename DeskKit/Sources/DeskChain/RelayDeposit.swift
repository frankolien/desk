import DeskAuth
import Foundation

/// A Relay deposit the wallet is about to sign, checked against what the user asked for.
///
/// The transaction arrives from a quote service, so every field is someone else's claim.
/// Signing is allowed only for `depositNative(depositor, id)` on Relay's depository, on
/// Monad mainnet, crediting this wallet, for exactly the typed amount. Anything else is a
/// different transaction wearing a quote's numbers.
public struct RelayDeposit: Sendable, Hashable {
    public enum Failure: Error, Sendable, Equatable {
        case wrongChain(UInt64)
        case unknownContract(String)
        case unexpectedCall
        case depositorIsNotThisWallet
        case amountMismatch
        case malformed
    }

    public static let chainID: UInt64 = 143
    /// RelayDepository's CREATE2 address, identical on every chain Relay deploys to. Listed as
    /// RelayDepository by L2Beat and in LI.FI's contract config, and bytecode is present on
    /// Monad mainnet.
    public static let depository = "4cd00e387622c35bddb9b4c962c136462338bc31"
    /// `depositNative(address,bytes32)`.
    public static let depositNativeSelector = "49290c1c"

    public let to: EthereumAddress
    public let data: Data
    public let value: NativeAmount

    public init(
        chainID: UInt64, to: String, data: String, value: String,
        wallet: EthereumAddress, amount: NativeAmount
    ) throws {
        guard chainID == Self.chainID else { throw Failure.wrongChain(chainID) }
        let target = Self.strip(to).lowercased()
        guard target == Self.depository, let address = Self.bytes(target).flatMap(EthereumAddress.init(bytes:)) else {
            throw Failure.unknownContract(to)
        }
        guard let calldata = Self.bytes(Self.strip(data)), calldata.count == 4 + 32 + 32 else {
            throw Failure.malformed
        }
        guard calldata.prefix(4).map({ String(format: "%02x", $0) }).joined() == Self.depositNativeSelector else {
            throw Failure.unexpectedCall
        }
        let word = calldata.dropFirst(4).prefix(32)
        guard word.prefix(12).allSatisfy({ $0 == 0 }), Data(word.suffix(20)) == wallet.bytes else {
            throw Failure.depositorIsNotThisWallet
        }
        guard value.allSatisfy(\.isASCIIDigit), !value.isEmpty, value == amount.weiText, !amount.isZero else {
            throw Failure.amountMismatch
        }
        self.to = address
        self.data = calldata
        self.value = amount
    }

    private static func strip(_ text: String) -> String {
        text.hasPrefix("0x") || text.hasPrefix("0X") ? String(text.dropFirst(2)) : text
    }

    private static func bytes(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}
